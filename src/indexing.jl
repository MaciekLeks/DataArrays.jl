## Unsafe scalar indexing

# Extract relevant fields of a DataArray to a tuple
# The extracted tuple can be passed to `unsafe_isna`,
# `unsafe_getindex_notna`, `unsafe_setna!`, `unsafe_setnotna!`, and
# `unsafe_dasetindex!`. This has a meaningful performance impact within
# very tight loops.
daextract(da::DataArray) = (da.data, da.na.chunks)
daextract(pda::PooledDataArray) = (pda.refs, pda.pool)
daextract(a) = nothing

# Check for NA
unsafe_isna(da::DataArray, extr, idx::Real) = Base.unsafe_bitgetindex(extr[2], idx)
unsafe_isna(pda::PooledDataArray, extr, idx::Real) = extr[1][idx] == 0
unsafe_isna(a, extr, idx::Real) = false
unsafe_getindex_notna(da::DataArray, extr, idx::Real) = getindex(extr[1], idx)
unsafe_getindex_notna(pda::PooledDataArray, extr, idx::Real) = getindex(extr[2], extr[1][idx])
unsafe_getindex_notna(a, extr, idx::Real) = Base.unsafe_getindex(a, idx)

# Set NA or data portion of DataArray

if VERSION < v"0.4.0-dev+2456"
    eval(quote
         unsafe_bitsettrue!(chunks::Vector{UInt64}, idx::Real) =
             chunks[Base.@_div64(@compat(Int(idx))-1)+1] |= (@compat(UInt64(1)) << Base.@_mod64(@compat(Int(idx))-1))
         unsafe_bitsetfalse!(chunks::Vector{UInt64}, idx::Real) =
             chunks[Base.@_div64(@compat(Int(idx))-1)+1] &= ~(@compat(UInt64(1)) << Base.@_mod64(@compat(Int(idx))-1))
         end)
else
    unsafe_bitsettrue!(chunks::Vector{UInt64}, idx::Real) =
        chunks[Base._div64(@compat(Int(idx))-1)+1] |= (@compat(UInt64(1)) << Base._mod64(@compat(Int(idx))-1))
    unsafe_bitsetfalse!(chunks::Vector{UInt64}, idx::Real) =
        chunks[Base._div64(@compat(Int(idx))-1)+1] &= ~(@compat(UInt64(1)) << Base._mod64(@compat(Int(idx))-1))
end

unsafe_setna!(da::DataArray, extr, idx::Real) = unsafe_bitsettrue!(extr[2], idx)
unsafe_setna!(da::PooledDataArray, extr, idx::Real) = setindex!(extr[1], 0, idx)
unsafe_setnotna!(da::DataArray, extr, idx::Real) = unsafe_bitsetfalse!(extr[2], idx)
unsafe_setnotna!(da::PooledDataArray, extr, idx::Real) = nothing

# Fast setting of NA values in DataArrays
# These take the data and chunks (extracted as da.data and
# da.na.chunks), a value, and a linear index. They assume
# a certain initialization pattern:
#
# - For DataArrays, da.na should be falses
# - For PooledDataArrays, pda.refs should be zeros
unsafe_dasetindex!(data::Array, na_chunks::Vector{UInt64}, val::NAtype, idx::Real) =
    unsafe_bitsettrue!(na_chunks, idx)
unsafe_dasetindex!(data::Array, na_chunks::Vector{UInt64}, val, idx::Real) =
    setindex!(data, val, idx)
unsafe_dasetindex!(da::DataArray, extr, val::NAtype, idx::Real) =
    unsafe_setna!(da, extr, idx)
unsafe_dasetindex!(da::PooledDataArray, extr, val::NAtype, idx::Real) = nothing
unsafe_dasetindex!(da::DataArray, extr, val, idx::Real) = setindex!(extr[1], val, idx)
unsafe_dasetindex!(pda::PooledDataArray, extr, val, idx::Real) =
    setindex!(extr[1], getpoolidx(pda, val), idx)
unsafe_dasetindex!(a::AbstractArray, extr, val, idx::Real) = setindex!(a, val, idx)

## PooledDataArray helper functions

# Append newpool to pool. Return indices of newpool in pool.
function combine_pools!(pool, newpool)
    seen = Dict{eltype(pool),Int}()
    sizehint!(seen, length(pool)+length(newpool))

    # Create mapping from pool elements to indices
    i = 0
    for elem in pool
        seen[elem] = (i += 1)
    end

    # Find pool elements in existing array, or add them
    poolidx = Array(Int, length(newpool))
    for j = 1:length(newpool)
        poolidx[j] = Base.@get!(seen, newpool[j], (push!(pool, newpool[j]); i += 1))
    end
    poolidx
end

## General indexing functions

# Indexing with NA throws an error
function Base.to_index(A::DataArray)
    any(A.na) && throw(NAException("cannot index an array with a DataArray containing NA values"))
    Base.to_index(A.data)
end

# Fast implementation of checkbounds for DataArray input
# This overrides an internal API that changed after JuliaLang/julia#10525,
# and which was finally stabilized and documented with JuliaLang/julia#11895.
if VERSION < v"0.4-dev+5194"
    Base.checkbounds(sz::Int, I::AbstractDataVector{Bool}) =
        length(I) == sz || throw(BoundsError())
    function Base.checkbounds{T<:Real}(sz::Int, I::AbstractDataArray{T})
        anyna(I) && throw(NAException("cannot index into an array with a DataArray containing NAs"))
        extr = daextract(I)
        for i = 1:length(I)
            @inbounds v = unsafe_getindex_notna(I, extr, i)
            checkbounds(sz, v)
        end
    end
elseif VERSION < v"0.4-dev+6993"
    Base._checkbounds(sz::Int, I::AbstractDataVector{Bool}) = length(I) == sz
    function Base._checkbounds{T<:Real}(sz::Int, I::AbstractDataArray{T})
        anyna(I) && throw(NAException("cannot index into an array with a DataArray containing NAs"))
        extr = daextract(I)
        b = true
        for i = 1:length(I)
            @inbounds v = unsafe_getindex_notna(I, extr, i)
            b &= Base._checkbounds(sz, v)
        end
        b
    end
else
    Base.checkbounds(::Type{Bool}, sz::Int, I::AbstractDataVector{Bool}) = length(I) == sz
    function Base.checkbounds{T<:Real}(::Type{Bool}, sz::Int, I::AbstractDataArray{T})
        anyna(I) && throw(NAException("cannot index into an array with a DataArray containing NAs"))
        extr = daextract(I)
        b = true
        for i = 1:length(I)
            @inbounds v = unsafe_getindex_notna(I, extr, i)
            b &= Base.checkbounds(Bool, sz, v)
        end
        b
    end
end

# Indexing uses undocumented APIs to determine the resulting shape. These APIs
# changed to support indices like `:`, which need the array to know the shape
if VERSION < v"0.4-dev+5194" # Merge commit of Julialang/julia#10525
    index_shape(A, I...) = Base.index_shape(I...)
    _lengths() = ()
    _lengths(i, I...) = tuple(length(i), _lengths(I...)...)
    index_lengths(A, I...) = _lengths(I...)
    function throw_setindex_mismatch(X, I)
        if length(I) == 1
            throw(DimensionMismatch("tried to assign $(length(X)) elements to $(I[1]) destinations"))
        else
            throw(DimensionMismatch("tried to assign $(Base.dims2string(size(X))) array to $(Base.dims2string(I)) destination"))
        end
    end
    setindex_shape_check(X::AbstractArray) =
        (length(X)==1 ||    throw_setindex_mismatch(X,()))
    setindex_shape_check(X::AbstractArray, i::Int) =
        (length(X)==i ||    throw_setindex_mismatch(X, (i,)))
    setindex_shape_check{T}(X::AbstractArray{T,1}, i::Int) =
        (length(X)==i ||    throw_setindex_mismatch(X, (i,)))
    setindex_shape_check{T}(X::AbstractArray{T,1}, i::Int, j::Int) =
        (length(X)==i*j ||  throw_setindex_mismatch(X, (i,j)))
    function setindex_shape_check{T}(X::AbstractArray{T,2}, i::Int, j::Int)
        if length(X) != i*j
            throw_setindex_mismatch(X, (i,j))
        end
        sx1 = size(X,1)
        if !(i == 1 || i == sx1 || sx1 == 1)
            throw_setindex_mismatch(X, (i,j))
        end
    end
    setindex_shape_check(X, I::Int...) = nothing # Non-arrays broadcast to all idxs
else
    import Base: index_shape, index_lengths, setindex_shape_check
end

# Fallbacks to avoid ambiguity
Base.setindex!(t::AbstractDataArray, x, i::Real) =
    throw(MethodError(setindex!, typeof(t), typeof(x), typeof(i)))
Base.getindex(t::AbstractDataArray, i::Real) =
    throw(MethodError(getindex, typeof(t), typeof(i)))

## getindex: DataArray

# Scalar case
function Base.getindex(da::DataArray, I::Real)
    if getindex(da.na, I)
        return NA
    else
        return getindex(da.data, I)
    end
end
@nsplat N function Base.getindex(da::DataArray, I::NTuple{N,Real}...)
    if getindex(da.na, I...)
        return NA
    else
        return getindex(da.data, I...)
    end
end

# Vector case
@ngenerate N typeof(dest) function _getindex!(dest::DataArray, src::DataArray,
                                              I::NTuple{N,(@compat Union{Int,AbstractVector})}...)
    Base.checksize(dest, I...)
    stride_1 = 1
    @nexprs N d->(stride_{d+1} = stride_d*size(src,d))
    @nexprs N d->(offset_d = 1)  # only really need offset_$N = 1
    k = 1
    srcextr = daextract(src)
    destextr = daextract(dest)
    @nloops N i dest d->(@inbounds offset_{d-1} = offset_d + (Base.unsafe_getindex(I_d, i_d)-1)*stride_d) begin
        @inbounds if unsafe_isna(src, srcextr, offset_0)
            unsafe_dasetindex!(dest, destextr, NA, k)
        else
            unsafe_dasetindex!(dest, destextr, unsafe_getindex_notna(src, srcextr, offset_0), k)
        end
        k += 1
    end
    dest
end

function _getindex{T}(A::DataArray{T}, I::@compat Tuple{Vararg{Union{Int,AbstractVector}}})
    shape = index_shape(A, I...)
    _getindex!(DataArray(Array(T, shape), falses(shape)), A, I...)
end

if VERSION >= v"0.4.0-dev+5578"
    @nsplat N function Base.getindex(A::DataArray, I::NTuple{N,(@compat Union{Real,AbstractVector})}...)
        checkbounds(A, I...)
        _getindex(A, Base.to_indexes(I...))
    end
else
    @nsplat N function Base.getindex(A::DataArray, I::NTuple{N,(@compat Union{Real,AbstractVector})}...)
        checkbounds(A, I...)
        _getindex(A, Base.to_index(I...))
    end
end

# Dispatch our implementation for these cases instead of Base
function Base.getindex(A::DataArray, I::AbstractVector)
    checkbounds(A, I)
    _getindex(A, (Base.to_index(I),))
end
function Base.getindex(A::DataArray, I::AbstractArray)
    checkbounds(A, I)
    _getindex(A, (Base.to_index(I),))
end

## getindex: PooledDataArray

# Scalar case
function Base.getindex(pda::PooledDataArray, I::Real)
    if getindex(pda.refs, I) == 0
        return NA
    else
        return pda.pool[getindex(pda.refs, I)]
    end
end
@nsplat N function Base.getindex(pda::PooledDataArray, I::NTuple{N,Real}...)
    if getindex(pda.refs, I...) == 0
        return NA
    else
        return pda.pool[getindex(pda.refs, I...)]
    end
end

# Vector case
@nsplat N function Base.getindex(A::PooledDataArray, I::NTuple{N,(@compat Union{Real,AbstractVector})}...)
    PooledDataArray(RefArray(getindex(A.refs, I...)), copy(A.pool))
end

# Dispatch our implementation for these cases instead of Base
Base.getindex(A::PooledDataArray, I::AbstractVector) =
    PooledDataArray(RefArray(getindex(A.refs, I)), copy(A.pool))
Base.getindex(A::PooledDataArray, I::AbstractArray) =
    PooledDataArray(RefArray(getindex(A.refs, I)), copy(A.pool))

## setindex!: DataArray

function Base.setindex!(da::DataArray, val::NAtype, i::Real)
    da.na[i] = true
    return da
end

function Base.setindex!(da::DataArray, val, ind::Real)
    da.data[ind] = val
    da.na[ind] = false
    return da
end

## setindex!: PooledDataArray

function Base.setindex!(pda::PooledDataArray, val::NAtype, ind::Real)
    pda.refs[ind] = 0
    return pda
end

function Base.setindex!(x::PooledDataArray, val, ind::Real)
    x.refs[ind] = getpoolidx(x, val)
    return x
end

## setindex!: both DataArray and PooledDataArray

@ngenerate N typeof(A) function Base.setindex!(A::AbstractDataArray, x,
                                               J::NTuple{N,(@compat Union{Real,AbstractArray})}...)
    if !isa(x, AbstractArray) && isa(A, PooledDataArray)
        # Only perform one pool lookup when assigning a scalar value in
        # a PooledDataArray
        setindex!(A.refs, getpoolidx(A, x), J...)
        return A
    end

    Aextr = daextract(A)
    @ncall N checkbounds A J
    @nexprs N d->(I_d = Base.to_index(J_d))
    stride_1 = 1
    @nexprs N d->(stride_{d+1} = stride_d*size(A,d))
    @nexprs N d->(offset_d = 1)  # really only need offset_$N = 1
    if !isa(x, AbstractArray)
        @nloops N i d->(1:length(I_d)) d->(@inbounds offset_{d-1} = offset_d + (Base.unsafe_getindex(I_d, i_d)-1)*stride_d) begin
            if isa(x, NAtype)
                @inbounds unsafe_setna!(A, Aextr, offset_0)
            else
                @inbounds unsafe_setnotna!(A, Aextr, offset_0)
                @inbounds unsafe_dasetindex!(A, Aextr, x, offset_0)
            end
        end
    else
        X = x
        idxlens = @ncall N index_lengths A I
        @ncall N setindex_shape_check X (d->idxlens[d])
        k = 1
        if isa(A, PooledDataArray) && isa(X, PooledDataArray)
            # When putting one PDA into another, first unify the pools
            # and then translate the references
            poolmap = combine_pools!(A.pool, X.pool)
            Arefs = A.refs
            Xrefs = X.refs
            @nloops N i d->(1:idxlens[d]) d->(@inbounds offset_{d-1} = offset_d + (Base.unsafe_getindex(I_d, i_d)-1)*stride_d) begin
                @inbounds Arefs[offset_0] = Xrefs[k] == 0 ? 0 : poolmap[Xrefs[k]]
                k += 1
            end
        else
            Xextr = daextract(X)
            @nloops N i d->(1:idxlens[d]) d->(@inbounds offset_{d-1} = offset_d + (Base.unsafe_getindex(I_d, i_d)-1)*stride_d) begin
                @inbounds if isa(X, AbstractDataArray) && unsafe_isna(X, Xextr, k)
                    unsafe_setna!(A, Aextr, offset_0)
                else
                    unsafe_setnotna!(A, Aextr, offset_0)
                    unsafe_dasetindex!(A, Aextr, unsafe_getindex_notna(X, Xextr, k), offset_0)
                end
                k += 1
            end
        end
    end
    A
end
