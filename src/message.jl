# Structs and constants related to the codes_handle type

export Message, getbytes, writemessage, missingvalue, clone, data, maskedvalues

mutable struct codes_handle
end

mutable struct Message
    ptr::Ptr{codes_handle}
end

"""
    Message(index::Index)
    Message(file::GribFile)

Retrieve the next message.

Returns `nothing` if there are no more messages.
"""
function Message(index::Index)::Union{Message, Nothing}
    eref = Ref(Int32(0))
    ptr = ccall((:codes_handle_new_from_index, eccodes), Ptr{codes_handle},
                (Ptr{codes_index}, Ref{Cint}), index.ptr, eref)
    if eref[] != 0 && eref[] != CODES_END_OF_INDEX
        throw(ErrorException("Error: $(errors[-eref[]+1])"))
    end
    if ptr == C_NULL || eref[] == CODES_END_OF_INDEX
        return nothing
    else
        m = Message(ptr)
        finalizer(destroy, m)
        return m
    end
end

function Message(file::GribFile)::Union{Message, Nothing}
    eref = Ref(Int32(0))
    ptr = ccall((:codes_grib_handle_new_from_file, eccodes), Ptr{codes_handle},
                (Ptr{codes_context}, Ptr{File}, Ref{Cint}),
                C_NULL, file.ptr, eref)
    file.pos += 1
    errorcheck(eref[])
    if ptr == C_NULL
        return nothing
    else
        m = Message(ptr)
        finalizer(destroy, m)
        return m
    end
end

"""
    Message(raw::Vector{UInt8})
    Message(messages::Vector{Vector{UInt8}})

Create a Message from a bytes array or array of bytes arrays.

The Message will share its underlying data with the inputed data.
"""
function Message(raw::Vector{UInt8})
    ptr = ccall((:codes_handle_new_from_message, eccodes), Ptr{codes_handle},
                (Ptr{codes_context}, Ptr{UInt8}, Csize_t),
                C_NULL, raw, length(raw))
    if ptr == C_NULL
        throw(ErrorException("Invalid message, could not create Message"))
    end
    m = Message(ptr)
    finalizer(destroy, m)
    return m
end

function Message(messages::Vector{Vector{UInt8}})
    sizes = map(length, messages)
    eref = Ref(Int32(0))
    ptr = ccall((:codes_grib_handle_new_from_multi_message, eccodes), Ptr{codes_handle},
                (Ptr{codes_context}, Ptr{Ptr{UInt8}}, Ptr{Csize_t}, Ptr{Cint}),
                C_NULL, messages, sizes, eref)
    errorcheck(eref[])
    m = Message(ptr)
    finalizer(destroy, m)
    return m
end

"""
    getbytes(message::Message)

Get a coded representation of the Message.
"""
function getbytes(message::Message)
    lenref = Ref(Csize_t(0))
    vp = Ref{Ptr{UInt8}}(C_NULL)
    err = ccall((:codes_get_message, eccodes), Cint,
                (Ptr{codes_handle}, Ptr{Ptr{UInt8}}, Ref{Csize_t}),
                message.ptr, vp, lenref)
    errorcheck(err)
    return unsafe_wrap(Vector{UInt8}, vp[], lenref[])
end

"""
    writemessage(handle::Message, filename::AbstractString; mode="c")

Write the message respresented by `handle` to the file at `filename`.

`mode` is a mode as described by `Base.open`.
"""
function writemessage(handle::Message, filename::AbstractString; mode="w")
    err = ccall((:codes_write_message, eccodes), Cint, (Ptr{codes_handle}, Cstring, Cstring),
                handle.ptr, filename, mode)
    errorcheck(err)
end

function Base.haskey(msg::Message, key::AbstractString)
    try
        msg[key]
        return true
    catch e
        return false
    end
end

"""
    missingvalue(msg::Message)

Return the missing value of the message. If one isn't included returns 1e30.
"""
function missingvalue(msg::Message)
    if haskey(msg, "missingValue")
        return msg["missingValue"]
    else
        return 1e30
    end
end

"""
    maskedvalues(msg::Message)

Return the values of the message masked so the missing value is `missing`.
"""
function maskedvalues(msg::Message)
    missingval = missingvalue(msg)
    vals = msg["values"]
    masked = Array{Union{Float64, Missing}, 2}(undef, size(vals)...)
    for i in eachindex(vals)
        @inbounds masked[i] = vals[i] == missingval ? missing : vals[i]
    end
    return masked
end

""" Get the native type of a key. """
function getnativetype(handle::Message, key::AbstractString)::DataType
    typeref = Ref(Int32(0))
    err = ccall((:codes_get_native_type, eccodes), Cint, (Ptr{codes_handle}, Cstring, Ref{Cint}),
                handle.ptr, key, typeref)
    errorcheck(err)
    typeint = typeref[]


    if typeint == CODES_TYPE_LONG
        return Clong
    elseif typeint == CODES_TYPE_STRING
        return String
    elseif typeint == CODES_TYPE_DOUBLE
        return Float64
    elseif typeint == CODES_TYPE_BYTES
        return Vector{UInt8}
    elseif typeint == CODES_TYPE_MISSING
        return Missing
    else
        return Tuple{}
    end
end

""" Get the number of values in a key. """
function getsize(message::Message, key::AbstractString)
    lenref = Ref(Csize_t(0))
    err = ccall((:codes_get_size, eccodes), Cint, (Ptr{codes_handle}, Cstring, Ref{Csize_t}),
                 message.ptr, key, lenref)
    errorcheck(err)
    return lenref[]
end

""" Get the value of a key. """
function Base.getindex(handle::Message, key::AbstractString)
    typ = getnativetype(handle, key)
    len = getsize(handle, key)
    if typ == String
        bufr = UInt(1024)
        bufref = Ref(bufr)
        mesg = zeros(Cuchar, bufr)
        err = ccall((:codes_get_string, eccodes), Cint,
                    (Ptr{codes_handle}, Cstring, Ptr{Cuchar}, Ref{Csize_t}),
                    handle.ptr, key, mesg, bufref)

        mesgstr = rstrip(transcode(String, mesg), '\0')
        errorcheck(err)
        return mesgstr
    elseif typ == Float64
        if len == 1
            valref = Ref(Float64(0))
            err = ccall((:codes_get_double, eccodes), Cint,
                        (Ptr{codes_handle}, Cstring, Ref{Cdouble}),
                        handle.ptr, key, valref)
            errorcheck(err)
            return valref[]
        else
            lenref = Ref(len)
            vals = Vector{Float64}(undef, len)
            err = ccall((:codes_get_double_array, eccodes), Cint,
                       (Ptr{codes_handle}, Cstring, Ref{Cdouble}, Ref{Csize_t}),
                        handle.ptr, key, vals, lenref)
            errorcheck(err)
            if key == "values"
                nj = handle["Nj"]
                ni = handle["Ni"]
                columnmajor = handle["jPointsAreConsecutive"] != 0
                if columnmajor
                    return reshape(vals, nj, ni)
                else
                    return reshape(vals, ni, nj)
                end
            else
                return vals
            end
        end
    elseif typ == Clong
        if len == 1
            valref = Ref(Clong(0))
            err = ccall((:codes_get_long, eccodes), Cint, (Ptr{codes_handle}, Cstring, Ref{Clong}),
                        handle.ptr, key, valref)
            errorcheck(err)
            return valref[]
        else
            lenref = Ref(len)
            vals = Vector{Clong}(undef, len)
            err = ccall((:codes_get_long_array, eccodes), Cint,
                       (Ptr{codes_handle}, Cstring, Ref{Clong}, Ref{Csize_t}),
                        handle.ptr, key, vals, lenref)
            errorcheck(err)
            return vals
        end
    elseif typ == Vector{UInt8}
        bufr = UInt(1024)
        bufref = Ref(bufr)
        mesg = Vector{UInt8}(undef, bufr)
        err = ccall((:codes_get_bytes, eccodes), Cint,
                    (Ptr{codes_handle}, Cstring, Ptr{Cuchar}, Ref{Csize_t}),
                    handle.ptr, key, mesg, bufref)
        errorcheck(err)
        return mesg[1:bufref[]]
    else
        throw(ErrorException("Could not get key: unsupported type"))
    end
end

"""
    setindex!(message::Message, value, key::AbstractString)

Set the value of a key.
"""
function Base.setindex!(handle::Message, value::Integer, key::AbstractString)
    err = ccall((:codes_set_long, eccodes), Cint, (Ptr{codes_handle}, Cstring, Clong),
                 handle.ptr, key, value)
    errorcheck(err)
end

function Base.setindex!(handle::Message, value::AbstractFloat, key::AbstractString)
    err = ccall((:codes_set_double, eccodes), Cint, (Ptr{codes_handle}, Cstring, Cdouble),
                 handle.ptr, key, value)
    errorcheck(err)
end

function Base.setindex!(handle::Message, value::AbstractString, key::AbstractString)
    lenref = Ref(Csize_t(length(value)))
    err = ccall((:codes_set_string, eccodes), Cint,
                (Ptr{codes_handle}, Cstring, Cstring, Ref{Csize_t}),
                 handle.ptr, key, value, lenref)
    errorcheck(err)
end

function Base.setindex!(handle::Message, value::Vector{UInt8}, key::AbstractString)
    lenref = Ref(Csize_t(length(value)))
    err = ccall((:codes_set_bytes, eccodes), Cint,
                (Ptr{codes_handle}, Cstring, Ref{UInt8}, Ref{Csize_t}),
                 handle.ptr, key, value, lenref)
    errorcheck(err)
end

function Base.setindex!(handle::Message, value::Array{Float64}, key::AbstractString)
    len = Csize_t(length(value))
    err = ccall((:codes_set_double_array, eccodes), Cint,
                (Ptr{codes_handle}, Cstring, Ref{Cdouble}, Csize_t),
                handle.ptr, key, value, len)
    errorcheck(err)
end

function Base.setindex!(handle::Message, value::Array{Clong}, key::AbstractString)
    len = Csize_t(length(value))
    err = ccall((:codes_set_long_array, eccodes), Cint,
                (Ptr{codes_handle}, Cstring, Ref{Clong}, Csize_t),
                 handle.ptr, key, value, len)
    errorcheck(err)
end

function Base.setindex!(handle::Message, value::Array{String}, key::AbstractString)
    len = Csize_t(length(value))
    err = ccall((:codes_set_string_array, eccodes), Cint,
                (Ptr{codes_handle}, Cstring, Ref{Cstring}, Csize_t),
                 handle.ptr, key, value, len)
    errorcheck(err)
end

""" Duplicate a message. """
function clone(handle::Message)::Union{Message, Nothing}
    ptr = ccall((:codes_handle_clone, eccodes), Ptr{codes_handle}, (Ptr{codes_handle},), handle.ptr)
    if ptr == C_NULL
        return nothing
    else
        m = Message(ptr)
        finalizer(destroy, m)
        return m
    end
end

# Aliases for clone for more Julian style
Message(handle::Message) = clone(handle)
Base.deepcopy(handle::Message) = clone(handle)

"""
    data(handle::Message)

Retrieve the longitudes, latitudes, and values from the message.

# Example
```
GribFile(filename) do f
    msg = Message(f)
    lons, lats, values = data(msg)
end
```
"""
function data(handle::Message)::Tuple{Array{Float64, 2}, Array{Float64, 2}, Array{Float64, 2}}
    # Allocate arrays
    npoints = handle["numberOfPoints"]
    lons = Vector{Float64}(undef, npoints)
    lats = Vector{Float64}(undef, npoints)
    values = Vector{Float64}(undef, npoints)
    err = ccall((:codes_grib_get_data, eccodes), Cint,
                (Ptr{codes_handle}, Ref{Cdouble}, Ref{Cdouble}, Ref{Cdouble}),
                handle.ptr, lats, lons, values)
    errorcheck(err)

    nj = handle["Nj"]
    ni = handle["Ni"]
    columnmajor = handle["jPointsAreConsecutive"] != 0
    if columnmajor
        return reshape(lons, nj, ni), reshape(lats, nj, ni), reshape(values, nj, ni)
    else
        return reshape(lons, ni, nj), reshape(lats, ni, nj), reshape(values, ni, nj)
    end
end

""" Safely destroy a message handle. """
function destroy(handle::Message)
    if handle.ptr != C_NULL
        err = ccall((:codes_handle_delete, eccodes), Cint, (Ptr{codes_handle},), handle.ptr)
        errorcheck(err)
        handle.ptr == C_NULL
    end
end

# Functions related to printing
function Base.show(io::IO, mime::MIME"text/plain", message::Message)
    dispkeys = ["date", "gridType", "stepRange", "typeOfLevel", "level",
                 "shortName", "name"]
    dispkeys = [k for k in dispkeys if haskey(message, k)]
    offsets = [9, 15, 10, 18, 6, 10, 4]
    line1 = strip(join([rpad(k, offsets[i]) for (i, k) in enumerate(dispkeys)])) * "\n"
    line2 = strip(join([rpad(message[k], offsets[i]) for (i, k) in enumerate(dispkeys)]))
    print(io, line1 * line2)
end

function Base.show(io::IO, message::Message)
    bytes = getbytes(message)
    str = bytes2hex(bytes)
    print(io, str)
end
