# This file is a part of Julia. License is MIT: https://julialang.org/license

#####################
# lattice utilities #
#####################

isType(@nospecialize t) = isa(t, DataType) && t.name === _TYPE_NAME

# true if Type{T} is inlineable as constant T
# requires that T is a singleton, s.t. T == S implies T === S
isconstType(@nospecialize t) = isType(t) && hasuniquerep(t.parameters[1])

# test whether type T has a unique representation, s.t. T == S implies T === S
function hasuniquerep(@nospecialize t)
    # typeof(Bottom) is special since even though it is a leaftype,
    # at runtime, it might be Type{Union{}} instead, so don't attempt inference of it
    t === typeof(Union{}) && return false
    t === Union{} && return true
    isa(t, TypeVar) && return false # TypeVars are identified by address, not equality
    iskindtype(typeof(t)) || return true # non-types are always compared by egal in the type system
    isconcretetype(t) && return true # these are also interned and pointer comparable
    if isa(t, DataType) && t.name !== Tuple.name # invariant DataTypes
        return _all(hasuniquerep, t.parameters)
    end
    return false
end

function has_nontrivial_const_info(@nospecialize t #=TODO (lattice overhaul) ::LatticeElement=#)
    isPartialStruct(t) && return true
    isPartialOpaque(t) && return true
    isConst(t) || return false
    val = constant(t)
    return !isdefined(typeof(val), :instance) && !(isa(val, Type) && hasuniquerep(val))
end

function has_const_info(x::LatticeElement)
    x = unwraptype(x)
    return (!isa(x, Type) && !isVararg(x)) || isType(x)
end

# Subtyping currently intentionally answers certain queries incorrectly for kind types. For
# some of these queries, this check can be used to somewhat protect against making incorrect
# decisions based on incorrect subtyping. Note that this check, itself, is broken for
# certain combinations of `a` and `b` where one/both isa/are `Union`/`UnionAll` type(s)s.
isnotbrokensubtype(@nospecialize(a), @nospecialize(b)) = (!iskindtype(b) || !isType(a) || hasuniquerep(a.parameters[1]) || b <: a)

argtypes_to_type(argtypes::Argtypes) = Tuple{anymap(a::LatticeElement -> isVararg(a) ? vararg(a) : widenconst(a), argtypes)...}

function isknownlength(t::DataType)
    isvatuple(t) || return true
    va = t.parameters[end]
    return isdefined(va, :N) && va.N isa Int
end

# Compute the minimum number of initialized fields for a particular datatype
# (therefore also a lower bound on the number of fields)
function datatype_min_ninitialized(t::DataType)
    isabstracttype(t) && return 0
    if t.name === NamedTuple_typename
        names, types = t.parameters[1], t.parameters[2]
        if names isa Tuple
            return length(names)
        end
        t = argument_datatype(types)
        t isa DataType || return 0
        t.name === Tuple.name || return 0
    end
    if t.name === Tuple.name
        n = length(t.parameters)
        n == 0 && return 0
        va = t.parameters[n]
        if isvarargtype(va)
            n -= 1
            if isdefined(va, :N)
                va = va.N
                if va isa Int
                    n += va
                end
            end
        end
        return n
    end
    return length(t.name.names) - t.name.n_uninitialized
end

has_concrete_subtype(d::DataType) = d.flags & 0x20 == 0x20 # n.b. often computed only after setting the type and layout fields

# determine whether x is a valid lattice element tag
# For example, Type{v} is not valid if v is a value
# Accepts TypeVars also, since it assumes the user will rewrap it correctly
function valid_as_lattice(@nospecialize(x))
    x === Bottom && false
    x isa TypeVar && return valid_as_lattice(x.ub)
    x isa UnionAll && (x = unwrap_unionall(x))
    if x isa Union
        # the Union constructor ensures this (and we'll recheck after
        # operations that might remove the Union itself)
        return true
    end
    if x isa DataType
        if isType(x)
            p = x.parameters[1]
            p isa Type || p isa TypeVar || return false
        end
        return true
    end
    return false
end

# test if non-Type, non-TypeVar `x` can be used to parameterize a type
function valid_tparam(@nospecialize(x))
    if isa(x, Tuple)
        for t in x
            isa(t, Symbol) || isbits(t) || return false
        end
        return true
    end
    return isa(x, Symbol) || isbits(x)
end

function compatible_vatuple(a::DataType, b::DataType)
    vaa = a.parameters[end]
    vab = a.parameters[end]
    if !(isvarargtype(vaa) && isvarargtype(vab))
        return isvarargtype(vaa) == isvarargtype(vab)
    end
    (isdefined(vaa, :N) == isdefined(vab, :N)) || return false
    !isdefined(vaa, :N) && return true
    return vaa.N === vab.N
end

# return an upper-bound on type `a` with type `b` removed
# such that `return <: a` && `Union{return, b} == Union{a, b}`
function typesubtract(@nospecialize(a), @nospecialize(b), MAX_UNION_SPLITTING::Int)
    if a <: b && isnotbrokensubtype(a, b)
        return Bottom
    end
    ua = unwrap_unionall(a)
    if isa(ua, Union)
        uua = typesubtract(rewrap_unionall(ua.a, a), b, MAX_UNION_SPLITTING)
        uub = typesubtract(rewrap_unionall(ua.b, a), b, MAX_UNION_SPLITTING)
        return Union{valid_as_lattice(uua) ? uua : Union{},
                     valid_as_lattice(uub) ? uub : Union{}}
    elseif a isa DataType
        ub = unwrap_unionall(b)
        if ub isa DataType
            if a.name === ub.name === Tuple.name &&
                    length(a.parameters) == length(ub.parameters)
                if 1 < unionsplitcost(a.parameters) <= MAX_UNION_SPLITTING
                    ta = switchtupleunion(a)
                    return typesubtract(Union{ta...}, b, 0)
                elseif b isa DataType
                    if !compatible_vatuple(a, b)
                        return a
                    end
                    # if exactly one element is not bottom after calling typesubtract
                    # then the result is all of the elements as normal except that one
                    notbottom = fill(false, length(a.parameters))
                    for i = 1:length(notbottom)
                        ap = unwrapva(a.parameters[i])
                        bp = unwrapva(b.parameters[i])
                        notbottom[i] = !(ap <: bp && isnotbrokensubtype(ap, bp))
                    end
                    let i = findfirst(notbottom)
                        if i !== nothing && findnext(notbottom, i + 1) === nothing
                            ta = collect(a.parameters)
                            ap = a.parameters[i]
                            bp = b.parameters[i]
                            (isvarargtype(ap) || isvarargtype(bp)) && return a
                            ta[i] = typesubtract(ap, bp, min(2, MAX_UNION_SPLITTING))
                            return Tuple{ta...}
                        end
                    end
                end
            end
        end
    end
    return a # TODO: improve this bound?
end

hasintersect(@nospecialize(a), @nospecialize(b)) = typeintersect(a, b) !== Bottom

function tvar_extent(@nospecialize t)
    while t isa TypeVar
        t = t.ub
    end
    return t
end

# N.B.: typename maps type equivalence classes to a single value
function typename_static(t::LatticeElement)
    isConditional(t) && return NativeType(Bool.name)
    isConst(t) && return _typename(constant(t))
    t = unwrap_unionall(widenconst(t))
    return isType(t) ? _typename(t.parameters[1]) : NativeType(Core.TypeName)
end

_typename(@nospecialize a) = ⊥
_typename(a::TypeVar) = NativeType(Core.TypeName)
function _typename(a::Union)
    ta = _typename(a.a)
    tb = _typename(a.b)
    ta === tb && return ta # same type-name
    (ta === ⊥ || tb === ⊥) && return ⊥ # threw an error
    (isConst(ta) && isConst(tb)) && return ⊥ # will throw an error (different type-names)
    return NativeType(Core.TypeName) # uncertain result
end
_typename(union::UnionAll) = _typename(union.body)
_typename(a::DataType) = Const(a.name)

# assume `isVararg(init)`
function tuple_tail_elem(init::LatticeElement, ct::Vector{LatticeElement})
    ct′ = Any[]
    for i = 1:length(ct)
        cti = ct[i]
        push!(ct′, isVararg(cti) ? vararg(cti) : widenconst(cti))
    end
    return NativeType(tuple_tail_elem(unwrapva(vararg(init)), ct′))
end

function tuple_tail_elem(@nospecialize(init), ct::Vector{Any})
    t = init
    for x in ct
        # FIXME: this is broken: it violates subtyping relations and creates invalid types with free typevars
        t = tmerge(t, unwraptv(unwrapva(x)))
    end
    return Vararg{widenconst(t)}
end

# Gives a cost function over the effort to switch a tuple-union representation
# as a cartesian product, relative to the size of the original representation.
# Thus, we count the longest element as being roughly invariant to being inside
# or outside of the Tuple/Union nesting, though somewhat more expensive to be
# outside than inside because the representation is larger (because and it
# informs the callee whether any splitting is possible).
function unionsplitcost(argtypes::Union{SimpleVector,Argtypes})
    nu = 1
    max = 2
    for ti in argtypes
        ti = unwraptype(ti)
        if isa(ti, Union)
            nti = unionlen(ti)
            if nti > max
                max, nti = nti, max
            end
            nu, ovf = Core.Intrinsics.checked_smul_int(nu, nti)
            ovf && return typemax(Int)
        end
    end
    return nu
end

# take a Tuple where one or more parameters are Unions
# and return an array such that those Unions are removed
# and `Union{return...} == ty`
function switchtupleunion(@nospecialize(ty))
    tparams = (unwrap_unionall(ty)::DataType).parameters
    return _switchtupleunion(Any[tparams...], length(tparams), [], ty)
end
function _switchtupleunion(t::Vector{Any}, i::Int, tunion::Vector{Any}, @nospecialize(origt))
    if i == 0
        tpl = rewrap_unionall(Tuple{t...}, origt)
        push!(tunion, tpl)
    else
        ti = t[i]
        if isa(ti, Union)
            for ty in uniontypes(ti)
                t[i] = ty
                _switchtupleunion(t, i - 1, tunion, origt)
            end
            t[i] = ti
        else
            _switchtupleunion(t, i - 1, tunion, origt)
        end
    end
    return tunion
end

switchtupleunion(argtypes::Argtypes) = _switchtupleunion(argtypes, length(argtypes), Argtypes[])
function _switchtupleunion(t::Argtypes, i::Int, tunion::Vector{Argtypes})
    if i == 0
        push!(tunion, copy(t))
    else
        ti = t[i]
        tyi = unwraptype(ti)
        if isa(tyi, Union)
            for ty in uniontypes(tyi)
                t[i] = NativeType(ty)
                _switchtupleunion(t, i - 1, tunion)
            end
            t[i] = ti
        else
            _switchtupleunion(t, i - 1, tunion)
        end
    end
    return tunion
end

# unioncomplexity estimates the number of calls to `tmerge` to obtain the given type by
# counting the Union instances, taking also into account those hidden in a Tuple or UnionAll
unioncomplexity(@nospecialize x) = _unioncomplexity(x)::Int
function _unioncomplexity(@nospecialize x)
    if isa(x, DataType)
        x.name === Tuple.name || isvarargtype(x) || return 0
        c = 0
        for ti in x.parameters
            c = max(c, unioncomplexity(ti))
        end
        return c
    elseif isa(x, Union)
        return unioncomplexity(x.a) + unioncomplexity(x.b) + 1
    elseif isa(x, UnionAll)
        return max(unioncomplexity(x.body), unioncomplexity(x.var.ub))
    elseif isa(x, TypeofVararg)
        return isdefined(x, :T) ? unioncomplexity(x.T) : 0
    else
        return 0
    end
end

# convert a Union of Tuple types to a Tuple of Unions
function unswitchtupleunion(u::Union)
    ts = uniontypes(u)
    n = -1
    for t in ts
        if t isa DataType && t.name === Tuple.name && length(t.parameters) != 0 && !isvarargtype(t.parameters[end])
            if n == -1
                n = length(t.parameters)
            elseif n != length(t.parameters)
                return u
            end
        else
            return u
        end
    end
    Tuple{Any[ Union{Any[t.parameters[i] for t in ts]...} for i in 1:n ]...}
end

function unwraptv(@nospecialize t)
    while isa(t, TypeVar)
        t = t.ub
    end
    return t
end
