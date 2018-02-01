using Base.Dates: Millisecond
import Base: getindex, convert
using .LazyTrees: LazyTree, data, children

mutable struct GeometryData{G <: Union{AbstractGeometry, AbstractMesh}, C <: Colorant, T <: Transformation}
    geometry::G
    color::C
    transform::T
end

GeometryData(g, c::Colorant) = GeometryData(g, c, IdentityTransformation())
GeometryData(g, t::Transformation) = GeometryData(g, RGBA(1, 0, 0, 0.5), t)

convert(::Type{G}, g::Union{AbstractGeometry, AbstractMesh}) where {G <: GeometryData} = GeometryData(g, RGBA(1, 0, 0, 0.5))

mutable struct VisData
    transform::Transformation
    geometries::Vector{GeometryData}
end

VisData() = VisData(IdentityTransformation(), GeometryData[])

const Path = Vector{Symbol}

struct CommandQueue
    delete::Set{Path}
    setgeometry::Set{Path}
    settransform::Set{Path}

    CommandQueue() = new(Set{Path}(), Set{Path}(), Set{Path}())
end

isempty(queue::CommandQueue) = isempty(queue.delete) && isempty(queue.setgeometry) && isempty(queue.settransform)

function empty!(queue::CommandQueue)
    empty!(queue.delete)
    empty!(queue.setgeometry)
    empty!(queue.settransform)
end

const VisTree = LazyTree{Symbol, VisData}

mutable struct CoreVisualizer
    context::ZMQ.Context
    socket::ZMQ.Socket
    url::String
    tree::VisTree
    queue::CommandQueue
    publish_immediately::Bool
    window::Nullable{Window}

    function CoreVisualizer(;spawn=true, url=nothing, script=nothing)
        if spawn
            window = Nullable(Window(url=url, script=script))
        else
            window = Nullable{Window}()
        end
        if url === nothing
            if !spawn
                error("Please either specify a url to connect to or set `spawn=true` to start a new visualizer")
            end
            url = get(window).url
        end
        context = ZMQ.Context()
        socket = ZMQ.Socket(context, ZMQ.REQ)
        ZMQ.connect(socket, url)
        vis = new(context, socket, url, VisTree(), CommandQueue(), true, window)
        vis
    end
end

# request_channel(vis::CoreVisualizer) = "DIRECTOR_TREE_VIEWER_REQUEST_<$(vis.client_id)>"
# response_channel(vis::CoreVisualizer) = "DIRECTOR_TREE_VIEWER_RESPONSE_<$(vis.client_id)>"

function setgeometry!(vis::CoreVisualizer, path::AbstractVector)
    push!(vis.queue.setgeometry, path)
    settransform!(vis, path)
end

function setgeometry!(vis::CoreVisualizer, path::AbstractVector, geoms::AbstractVector)
    vis.tree[path].data.geometries = geoms
    setgeometry!(vis, path)
end

function addgeometry!(vis::CoreVisualizer, path::AbstractVector, geoms::AbstractVector)
    append!(vis.tree[path].data.geometries, geoms)
    setgeometry!(vis, path)
end

setgeometry!(vis::CoreVisualizer, path::AbstractVector, geom) = setgeometry!(vis, path, [geom])
addgeometry!(vis::CoreVisualizer, path::AbstractVector, geom) = addgeometry!(vis, path, [geom])

setgeometry!(vis::CoreVisualizer, path::AbstractVector, geom::AbstractGeometry) =
    setgeometry!(vis, path, GeometryData(geom))
addgeometry!(vis::CoreVisualizer, path::AbstractVector, geom::AbstractGeometry) =
    addgeometry!(vis, path, GeometryData(geom))

function settransform!(vis::CoreVisualizer, path::AbstractVector)
    push!(vis.queue.settransform, path)
    if vis.publish_immediately
        publish!(vis)
    end
end

function settransform!(vis::CoreVisualizer, path::AbstractVector, tform)
    vis.tree[path].data.transform = tform
    settransform!(vis, path)
end

function delete!(vis::CoreVisualizer, path::AbstractVector)
    delete!(vis.tree, path)
    push!(vis.queue.delete, path)
    if vis.publish_immediately
        publish!(vis)
    end
end

function publish!(vis::CoreVisualizer)
    if !isempty(vis.queue)
        data = serialize(vis, vis.queue)
        ZMQ.send(vis.socket, data)
        ZMQ.recv(vis.socket)
        # println(unsafe_string(ZMQ.recv(vis.socket)))
        # msg = to_lcm(data)
        # publish(vis.lcm, request_channel(vis), msg)
        empty!(vis.queue)
    end
end

# function onresponse(vis::CoreVisualizer, msg)
#     data = JSON.parse(IOBuffer(msg.data))
#     if data["status"] == 0
#         empty!(vis.queue)
#     elseif data["status"] == 1
#         for path in LazyTrees.descendants(vis.tree)
#             push!(vis.queue.setgeometry, path)
#             push!(vis.queue.settransform, path)
#         end
#         publish!(vis)
#     else
#         error("unhandled: $data")
#     end
# end

# function to_lcm(data::Associative)
#     jsondata = JSON.json(data)
#     Comms.CommsT(
#         data["utime"],
#         "treeviewer_json",
#         1,
#         0,
#         length(jsondata),
#         jsondata)
# end

struct Visualizer
    core::CoreVisualizer
    path::Vector{Symbol}

    Visualizer(;url=nothing, spawn=true) = new(CoreVisualizer(spawn=spawn, url=url), Symbol[])
    Visualizer(core::CoreVisualizer, path::AbstractVector) = new(core, path)
end

show(io::IO, vis::Visualizer) = print(io, "Visualizer with path prefix $(vis.path) using ZMQ URL $(vis.core.url)")

function setgeometry!(vis::Visualizer)
    setgeometry!(vis.core, vis.path)
    vis
end

function setgeometry!(vis::Visualizer, geom)
    setgeometry!(vis.core, vis.path, geom)
    vis
end

function addgeometry!(vis::Visualizer, geom)
    addgeometry!(vis.core, vis.path, geom)
    vis
end

settransform!(vis::Visualizer) = settransform!(vis.core, vis.path)
settransform!(vis::Visualizer, transform) = settransform!(vis.core, vis.path, transform)
delete!(vis::Visualizer) = delete!(vis.core, vis.path)
publish!(vis::Visualizer) = publish!(vis.core)

getindex(vis::Visualizer, path::Symbol) = Visualizer(vis.core, vcat(vis.path, path))
getindex(vis::Visualizer, path::AbstractVector) = Visualizer(vis.core, vcat(vis.path, path))

function batch(func, vis::Visualizer)
    old_publish_flag = vis.core.publish_immediately
    try
        vis.core.publish_immediately = false
        func(vis)
        if old_publish_flag
            publish!(vis)
        end
    finally
        vis.core.publish_immediately = old_publish_flag
    end
end

# Old-style visualizer interface
function Visualizer(geom::GeometryData; kwargs...)
    vis = Visualizer(;kwargs...)[:anonymous]
    setgeometry!(vis, geom)
    vis
end

Visualizer(geom::Union{AbstractGeometry, AbstractMesh}) = Visualizer(GeometryData(geom))

Base.close(vis::Visualizer) = close(vis.core)

function Base.close(core::CoreVisualizer)
    if isnull(core.window)
        warn("Visualizer has no attached window, so I cannot kill its window process")
    else
        kill(get(core.window).proc)
    end
    close(core.socket)
end
