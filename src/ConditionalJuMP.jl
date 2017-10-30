__precompile__()

module ConditionalJuMP

using JuMP
using JuMP: GenericAffExpr, GenericRangeConstraint, Variable, AbstractJuMPScalar
using IntervalArithmetic: Interval
import Base: <=, ==, >=, !, &, hash, show

export @disjunction,
    @implies,
    @?,
    @switch,
    @ifelse,
    warmstart!,
    upperbound,
    lowerbound

include("macros.jl")

const NArg{N} = NTuple{N, Any}

function simplify(e::JuMP.GenericAffExpr{T, Variable}) where T
    coeffs = Dict{Variable, T}()
    for i in eachindex(e.vars)
        v, c = e.vars[i], e.coeffs[i]
        if c != 0
            coeffs[v] = get(coeffs, v, zero(T)) + c
        end
    end
    pairs = collect(coeffs)
    constant = e.constant
    if iszero(constant)
        constant = zero(constant)
    end
    AffExpr(first.(pairs), last.(pairs), constant)
end

function normalize(c::GenericRangeConstraint)
    @assert c.ub != Inf || c.lb != -Inf "Can't construct a constraint with infinite lower and upper bounds"

    terms = c.terms
    lb = c.lb
    ub = c.ub
    if ub == Inf
        # then flip the constraint over so its upper bound is finite
        lb, ub = -ub, -lb
        terms = -terms
    end
    if ub != 0
        x = ub
        ub = 0
        terms -= x
        lb -= x
    end
    if iszero(lb)
        # Ensure that we don't have negative zeros so that hashing is reliable
        lb = zero(lb)
    end
    if iszero(ub)
        ub = zero(ub)
    end
    GenericRangeConstraint(simplify(terms), lb, ub)
end


struct Constraint{T}
    c::GenericRangeConstraint{GenericAffExpr{T, Variable}}
    function Constraint{T}(c::GenericAffExpr{T}, lb, ub) where T
        new(normalize(GenericRangeConstraint{GenericAffExpr{T, Variable}}(c, lb, ub)))
    end
end

function Constraint(c::GenericAffExpr{T1}, lb::T2, ub::T3) where {T1, T2, T3}
    Constraint{promote_type(T1, T2, T3)}(c, lb, ub)
end

# work-around because JuMP doesn't properly define hash()
function Base.hash(x::Constraint, h::UInt)
    h = hash(x.c.lb, h)
    h = hash(x.c.ub, h)
    h = hash(x.c.terms.constant, h)
    for v in x.c.terms.vars
        h = hash(v, h)
    end
    for c in x.c.terms.coeffs
        h = hash(c, h)
    end
    h
end

(==)(e1::Constraint, e2::Constraint) = (e1.c.lb == e2.c.lb) && (e1.c.ub == e2.c.ub) && (e1.c.terms == e2.c.terms)

show(io::IO, h::Constraint) = print(io, h.c)

const Conditional = Set{Constraint{Float64}}


show(io::IO, c::Conditional) = print(io, join(c, " & "))

Conditional(::typeof(<=), x, y) = Conditional(Set([Constraint(x - y, -Inf, 0)]))
Conditional(::typeof(>=), x, y) = Conditional(Set([Constraint(y - x, -Inf, 0)]))
Conditional(::typeof(==), x, y) = Conditional(Set([Constraint(x - y, 0, 0)]))
(&)(c1::Conditional, c2::Conditional) = union(c1, c2)
Conditional() = Conditional(Set())

struct UnhandledComplementException <: Exception
    c::Conditional
end

function Base.showerror(io::IO, e::UnhandledComplementException)
    print(io, "The complement of condition $(e.c) cannot be automatically determined. You will need to manually specify a disjunction covering this condition and all of its alternatives")
end

# lb <= x <= ub
# -> x <= lb || x >= ub
hascomplement(c::Conditional) = (length(c) == 1) && (first(c).c.lb == -Inf || first(c).c.ub == Inf)
function complement(c::Conditional)
    hascomplement(c) || throw(UnhandledComplementException(c))
    constr = first(c).c
    if constr.lb == -Inf
        new_constr = Constraint(constr.terms, constr.ub, Inf)
    else
        @assert constr.ub == Inf
        new_constr = Constraint(constr.terms, -Inf, constr.lb)
    end
    Conditional([new_constr])
end
(!)(c::Conditional) = complement(c)

lowerbound(x::Number) = x
upperbound(x::Number) = x
lowerbound(x::Variable) = JuMP.getlowerbound(x)
upperbound(x::Variable) = JuMP.getupperbound(x)

function interval(e::JuMP.GenericAffExpr, needs_simplification=true)
    if needs_simplification
        e = simplify(e)
    end
    if isempty(e.coeffs)
        return Interval(e.constant, e.constant)
    else
        result = Interval(e.constant, e.constant)
        for i in eachindex(e.coeffs)
            var = e.vars[i]
            coef = e.coeffs[i]
            result += Interval(coef, coef) * Interval(getlowerbound(var), getupperbound(var))
        end
        return result
    end
end

upperbound(e::GenericAffExpr, simplify=true) = upperbound(interval(e, simplify))
lowerbound(e::GenericAffExpr, simplify=true) = lowerbound(interval(e, simplify))
lowerbound(i::Interval) = i.lo
upperbound(i::Interval) = i.hi

const Implication = Pair{Conditional, Conditional}

struct IndicatorMap
    model::Model
    indicators::Dict{Conditional, AffExpr}
    disjunctions::Vector{Vector{Implication}}
    y_idx::Base.RefValue{Int}
    z_idx::Base.RefValue{Int}
end

IndicatorMap(m::Model) = IndicatorMap(m, 
    Dict{Conditional, AffExpr}(), 
    Vector{Vector{Implication}}(),
    Ref(1),
    Ref(1))

getindmap!(m::Model) = get!(m.ext, :indicator_map, IndicatorMap(m))::IndicatorMap

function newcontinuousvar(m::IndicatorMap)
    var = @variable(m.model, basename="y_{anon$(m.y_idx[])}")
    m.y_idx[] = m.y_idx[] + 1
    var
end

function newcontinuousvar(m::IndicatorMap, size::Dims)
    var = reshape(@variable(m.model, [1:prod(size)], basename="{y_{anon$(m.y_idx[])}}"), size)
    m.y_idx[] = m.y_idx[] + 1
    var
end

newcontinuousvar(m::Model, args...) = newcontinuousvar(getindmap!(m), args...)

function newbinaryvar(m::IndicatorMap)
    var = @variable(m.model, basename="z_{anon$(m.z_idx[])}", category=:Bin)
    m.z_idx[] = m.z_idx[] + 1
    var
end

newbinaryvar(m::Model, args...) = newbinaryvar(getindmap!(m), args...)

function getindicator!(m::IndicatorMap, c::Conditional, can_create=true)
    if haskey(m.indicators, c)
        return m.indicators[c]
    else
        if !can_create
            @show c
            error("Not allowed to create a new variable here. Something has gone wrong")
        end
        z = convert(AffExpr, newbinaryvar(m))
        implies!(m.model, z, c)
        m.indicators[c] = z

        if hascomplement(c)
            m.indicators[!c] = 1 - z
        end
        return z
    end
end

getindicator!(m::Model, c::Conditional) = getindicator!(getindmap!(m), c)

function implies!(m::Model, z::AbstractJuMPScalar, c::Conditional)
    for constraint in c
        implies!(m, z, constraint)
    end
end

struct UnboundedVariableException <: Exception
    terms::AffExpr
end

function Base.showerror(io::IO, e::UnboundedVariableException)
    print(io, "Cannot create an implication involving the expression: $(e.terms) because not all of the variables in it are fully bounded. Please use `JuMP.setlowerbound()` and `JuMP.setupperbound()` to set finite bounds for all variables appearing in this expression.")
end

function implies!(m::Model, z::AbstractJuMPScalar, constraint::Constraint)
    expr_interval = interval(constraint.c.terms, false)
    if constraint.c.ub != Inf
        M = upperbound(expr_interval) - constraint.c.ub
        isfinite(M) || throw(UnboundedVariableException(constraint.c.terms))
        @constraint m constraint.c.terms <= constraint.c.ub + M * (1 - z)
    end
    if constraint.c.lb != -Inf
        M = constraint.c.lb - lowerbound(expr_interval)
        isfinite(M) || throw(UnboundedVariableException(constraint.c.terms))
        @constraint m constraint.c.terms >= constraint.c.lb - M * (1 - z)
    end
end

disjunction!(m::Model, args...) = disjunction!(getindmap!(m), args...)

function disjunction!(indmap::IndicatorMap, imps::NTuple{1, Implication})
    z = newbinaryvar(indmap)
    JuMP.fix(z, 1)
    lhs, rhs = imps[1]
    implies!(indmap.model, z, lhs)
    implies!(indmap.model, z, rhs)
    implies!(indmap.model, 1 - z, !lhs)
end

function disjunction!(indmap::IndicatorMap, imps::NTuple{2, Implication})
    z = getindicator!(indmap, first(imps[1]))
    implies!(indmap.model, z, last(imps[1]))
    indmap.indicators[first(imps[2])] = 1 - z
    implies!(indmap.model, 1 - z, first(imps[2]))
    implies!(indmap.model, 1 - z, last(imps[2]))
    push!(indmap.disjunctions, collect(imps))
end

function disjunction!(indmap::IndicatorMap, imps::Union{Tuple, AbstractArray})
    zs = getindicator!.(indmap, first.(imps))
    implies!.(indmap.model, zs, last.(imps))
    @constraint(indmap.model, sum(zs) == 1)
    push!(indmap.disjunctions, collect(imps))
end

function  disjunction!(indmap::IndicatorMap, 
                       conditions::Union{Tuple{Vararg{Conditional}},
                                         <:AbstractArray{Conditional}})
    disjunction!(indmap, (c -> (c => Conditional(Set()))).(conditions))
end

implies!(m::Model, imps::Implication...) = disjunction!(m, imps)

implies!(m::Model, imps::Pair...) = implies!(m, convert.(Implication, imps)...)

Base.convert(::Type{Conditional}, ::Void) = Conditional()

function implies!(m::Model, imp::Implication)
    c1, c2 = imp
    comp1 = !c1
    disjunction!(m, (imp, (comp1 => Conditional(Set()))))
end

getmodel(x::JuMP.Variable) = x.m
getmodel(x::JuMP.GenericAffExpr) = first(x.vars).m
getmodel(c::Constraint) = getmodel(c.c.terms)

function getmodel(c::Conditional)::Model
    for arg in c
        if !isempty(arg.c.terms.vars)
            return getmodel(arg)
        end
    end
    error("Could not find JuMP Model in conditional $c")
end

nan_to_null(x) = isnan(x) ? Nullable{typeof(x)}() : Nullable{typeof(x)}(x)

"""
Like JuMP.getvalue, but returns a Nullable{T}() for unset variables instead
of throwing a warning
"""
_getvalue(x::Variable) = nan_to_null(JuMP._getValue(x))
_getvalue(x::Number) = nan_to_null(x)

function _getvalue(x::JuMP.GenericAffExpr{T, Variable}) where {T}
    result::Nullable{T} = x.constant
    for i in eachindex(x.coeffs)
        result = result .+ x.coeffs[i] .* _getvalue(x.vars[i])
    end
    result
end

function _getvalue(h::Constraint)
    v = _getvalue(h.c.terms)
    max.(v .- h.c.ub, h.c.lb .- v)
end

_getvalue(c::Conditional) = maximum(_getvalue, c)

_setvalue(v::Variable, x) = JuMP.setvalue(v, x)
function _setvalue(s::JuMP.GenericAffExpr, x)
    @assert length(s.vars) == 1
    _setvalue(s.vars[1], (x - s.constant) / s.coeffs[1])
end

Base.show(io::IO, cv::Implication) = print(io, "(", first(cv), ") implies (", last(cv), ")")

Base.@pure isjump(x) = false
Base.@pure isjump(args::Tuple) = any(isjump, args)
Base.@pure isjump(arg::Pair) = isjump(arg.first)
Base.@pure isjump(c::Constraint) = true
Base.@pure isjump(c::Conditional) = any(isjump, c)
Base.@pure isjump(x::AbstractJuMPScalar) = true
Base.@pure isjump(x::AbstractArray{<:AbstractJuMPScalar}) = true

function _conditional(op::Op, args...) where {Op <: Union{typeof(<=), typeof(>=), typeof(==), typeof(in)}}
    if isjump(args)
        Conditional(op, args...)
    else
        op(args...)
    end
end

_conditional(op, args...) = op(args...)

function _all_conditional(args)
    (&)(args...)
end

function switch!(m::Model, args::Pair{<:Conditional}...)
    y = newcontinuousvar(m)
    conditions = first.(args)
    values = last.(args)
    setlowerbound(y, minimum(lowerbound, values))
    setupperbound(y, maximum(upperbound, values))
    disjunction!(m, map(cv -> (cv[1] => @?(y == cv[2])), args))
    y
end

function switch!(m::Model, args::Pair{<:Conditional, <:AbstractArray}...)
    y = newcontinuousvar(m, size(last(args[1])))
    conditions = first.(args)
    values = last.(args)
    for I in eachindex(y)
        setlowerbound(y[I], minimum(v -> lowerbound(v[I]), values))
        setupperbound(y[I], maximum(v -> upperbound(v[I]), values))
    end
    disjunction!(m, map(cv -> (cv[1] => @?(y .== cv[2])), args))
    y
end


function Base.ifelse(c::Conditional, v1, v2)
    @assert size(v1) == size(v2)
    m = getmodel(c)
    y = newcontinuousvar(m)
    setlowerbound.(y, min.(lowerbound.(v1), lowerbound.(v2)))
    setupperbound.(y, max.(upperbound.(v1), upperbound.(v2)))
    disjunction!(m, (c => @?(y == v1), !c => @?(y == v2)))
    y
end

function Base.ifelse(c::Conditional, v1::AbstractArray, v2::AbstractArray)
    @assert size(v1) == size(v2)
    m = getmodel(c)
    y = newcontinuousvar(m, size(v1))
    setlowerbound.(y, min.(lowerbound.(v1), lowerbound.(v2)))
    setupperbound.(y, max.(upperbound.(v1), upperbound.(v2)))
    @disjunction(m, (c => y .== v1), (!c => (y .== v2)))
    # disjunction!(m, (c => @?(y .== v1), !c => @?(y .== v2)))
    y
end

isfixed(v::Variable) = JuMP.getcategory(v) == :Fixed
isfixed(s::JuMP.GenericAffExpr) = all(isfixed, s.vars)

_fix(v::Variable, x) = JuMP.fix(v, x)

function _fix(s::JuMP.GenericAffExpr, x)
    @assert length(s.vars) == 1
    @assert s.coeffs[1] != 0
    JuMP.fix(s.vars[1], (x - s.constant) / s.coeffs[1])
    @assert get(_getvalue(s)) ≈ x
end

_unfix(v::Variable) = JuMP.setcategory(v, :Bin)

function _unfix(s::JuMP.GenericAffExpr)
    @assert length(s.vars) == 1
    JuMP.setcategory(s.vars[1], :Bin)
    setlowerbound(s.vars[1], 0)
    setupperbound(s.vars[1], 1)
end

function _setvalue(m::Model, c::Conditional)
    if length(c) != 1
        return nothing
    end
    constraint = first(c).c
    if isfinite(constraint.lb) && constraint.lb == constraint.ub
        _setvalue(constraint.terms, constraint.ub)
    end
    return nothing
end

function warmstart!(m::Model, fix=false)
    indmap = getindmap!(m)
    while true
        modified = false
        for implications in indmap.disjunctions
            violations = Nullable{Float64}[_getvalue(first(i)) for i in implications]
            if !any(isnull, violations)
                best_match = indmin(get.(violations))
                for i in eachindex(violations)
                    imp = implications[i]
                    lhs, rhs = imp
                    z = getindicator!(indmap, lhs, false)
                    satisfied = i == best_match
                    if fix
                        if !isfixed(z)
                            modified = true
                        end
                        _fix(z, satisfied)
                    else
                        if isnull(_getvalue(z))
                            modified = true
                        end
                        _unfix(z)
                        _setvalue(z, satisfied)
                    end
                    if satisfied
                        _setvalue(m, rhs)
                    end
                end
            end
        end
        if !modified
            break
        end
    end
end

function switch(args::Pair...)
    if isjump(args)
        switch!(getmodel(args[1].first), args...)
    else
        for arg in args
            if arg.first
                return last(arg)
            end
        end
        error("One of the cases in the switch statement must always match")
    end
end

end