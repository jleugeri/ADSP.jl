export Synapse, Segment, Neuron, Network, Input, Logger
using DataFrames: DataFrame


################################################################################
## model component definitions                                                ##
################################################################################


abstract type AbstractComponent{ID,T,WT,IT} end
abstract type NeuronOrSegmentOrOutput{ID,T,WT,IT} <: AbstractComponent{ID,T,WT,IT} end
abstract type NeuronOrSegment{ID,T,WT,IT} <: NeuronOrSegmentOrOutput{ID,T,WT,IT} end
abstract type AbstractNetwork{ID,T,WT,IT} <:AbstractComponent{ID,T,WT,IT} end
abstract type AbstractSynapse{ID,T,WT,IT} <:AbstractComponent{ID,T,WT,IT} end

struct Segment{ID,T,WT,IT} <: NeuronOrSegment{ID,T,WT,IT}
    id::ID
    θ_syn::IT
    θ_seg::Int
    plateau_duration::T

    state_syn::Ref{IT}
    state_seg::Ref{Int}
    last_activated::Ref{T}
    state::Ref{Bool}
    
    next_downstream::NeuronOrSegment{ID,T,WT,IT}
    next_upstream::Vector{Segment{ID,T,WT,IT}}
    net::AbstractNetwork{ID,T,WT,IT}

    function Segment(id::ID, root::NeuronOrSegment{ID,T,WT,IT}; θ_syn=1, θ_seg=1, plateau_duration=root.net.default_plateau_duration) where {ID,T,WT,IT}
        this = new{ID,T,WT,IT}(id, θ_syn, θ_seg, plateau_duration, Ref(zero(IT)), Ref(0), Ref(zero(T)), Ref(false), root, Segment{ID,T,WT,IT}[], root.net)
        push!(root.next_upstream, this)
        return this
    end
end

struct Synapse{ID,T,WT,IT} <: AbstractSynapse{ID,T,WT,IT}
    id::ID
    target::NeuronOrSegmentOrOutput{ID,T,WT,IT}
    delay::T
    spike_duration::T
    weight::WT
    magnitude::Ref{IT}
    state::Ref{Bool}

    net::AbstractNetwork{ID,T,WT,IT}

    function Synapse(
                id::ID, source, target::NeuronOrSegmentOrOutput{ID,T,WT,IT}; 
                delay::T = source.net.default_delay, spike_duration::T = source.net.default_spike_duration, weight::WT=one(IT)
            ) where {ID,T,WT,IT}
        this = new{ID,T,WT,IT}(id, target, delay, spike_duration, weight, Ref(zero(IT)), Ref(false), source.net)
        push!(source.synapses, this)
        return this
    end
end
sample_spike_magnitude(weight)=weight

struct Neuron{ID,T,WT,IT} <: NeuronOrSegment{ID,T,WT,IT}
    id::ID
    θ_syn::IT
    θ_seg::Int
    refractory_duration::T

    state_syn::Ref{IT}
    state_seg::Ref{Int}
    state::Ref{Bool}

    next_upstream::Vector{Segment{ID,T,WT,IT}}
    synapses::Vector{Synapse{ID,T,WT,IT}}
    net::AbstractNetwork{ID,T,WT,IT}
    
    function Neuron(id::ID, net::AbstractComponent{ID,T,WT,IT}; θ_syn=one(IT), θ_seg=1, refractory_duration::T=net.default_refractory_duration) where {ID,T,WT,IT}
        this = new{ID,T,WT,IT}(id,θ_syn,θ_seg,refractory_duration,Ref(zero(IT)),Ref(0), Ref(false),Segment{ID,T,WT,IT}[],Synapse{ID,T,WT,IT}[],net)
        push!(net.neurons, this)
        return this
    end
end

struct Input{ID,T,WT,IT} <: AbstractComponent{ID,T,WT,IT}
    id::ID
    synapses::Vector{Synapse{ID,T,WT,IT}}
    net::AbstractNetwork{ID,T,WT,IT}

    function Input(id::ID, net::AbstractComponent{ID,T,WT,IT}) where {ID,T,WT,IT}
        this = new{ID,T,WT,IT}(id::ID,Synapse{ID,T,WT,IT}[],net)
        push!(net.inputs, this)
        return this
    end
end

struct Output{ID,T,WT,IT} <: NeuronOrSegmentOrOutput{ID,T,WT,IT}
    id::ID
    net::AbstractNetwork{ID,T,WT,IT}
    state_syn::Ref{IT}

    function Output(id::ID, net::AbstractComponent{ID,T,WT,IT}) where {ID,T,WT,IT}
        this = new{ID,T,WT,IT}(id::ID, net, Ref(zero(IT)))
        push!(net.outputs, this)
        return this
    end
end

struct Network{ID,T,WT,IT} <: AbstractNetwork{ID,T,WT,IT}
    inputs::Vector{Input{ID,T,WT,IT}}
    outputs::Vector{Output{ID,T,WT,IT}}
    neurons::Vector{Neuron{ID,T,WT,IT}}

    default_refractory_duration::T
    default_delay::T
    default_spike_duration::T
    default_plateau_duration::T

    Network(;
        id_type::Type=Symbol, time_type::Type=Float64, weight_type::Type=Int, synaptic_input_type::Type=Int, 
        default_refractory_duration = 1.0, default_delay = 1.0, default_spike_duration = 5.0, default_plateau_duration = 100.0
    ) = new{id_type, time_type, weight_type, synaptic_input_type}(
            Input{id_type, time_type, weight_type, synaptic_input_type}[], 
            Output{id_type, time_type, weight_type, synaptic_input_type}[], 
            Neuron{id_type, time_type, weight_type, synaptic_input_type}[],
            default_refractory_duration, default_delay, default_spike_duration, default_plateau_duration
        )
end

################################################################################
## default simulation handling                                                ##
################################################################################

struct Event{T, V}
    type::Symbol
    created::T
    t::T
    target::V
end
Base.isless(ev1::Event, ev2::Event) = isless(ev1.t, ev2.t)

function handle!(event::Event, queue!, logger!)
    if event.type == :input_spikes
        # definitely turn input on 
        # -> this will trigger all synapses to fire
        on!(event.target, event.t, queue!, logger!)
    elseif event.type == :epsp_starts
        # definitively turn synapse on -> this may trigger a cascade of segements / soma to emit plateaus / a spike
        on!(event.target, event.t, queue!, logger!)
    elseif event.type == :epsp_ends
        # definitively turn synapse off
        off!(event.target, event.t, queue!, logger!)
    elseif event.type == :plateau_ends
        # if the event is not relevant any more (the current plateau is not the one that triggered this event), ignore
        # if the event is still relevant, definitely turn the segment off 
        # -> this may also turn off upstream segments
        if event.created >= event.target.last_activated[]
            maybe_off!(event.target, event.t, queue!, logger!)
        end
    elseif event.type == :refractory_period_ends
        # definitively enable neuron to fire again
        # -> this may also trigger another spike rightaway
        # -> a spike will trigger all synapses to fire
        maybe_off!(event.target, event.t, queue!, logger!)
    end
    nothing
end

################################################################################
## model behavior                                                             ##
################################################################################

function reset!(net::Network{ID,T,WT,IT}) where {ID,T,WT,IT}
    foreach(reset!, net.inputs)
    foreach(reset!, net.outputs)
    foreach(reset!, net.neurons)
end

function reset!(x::Neuron{ID,T,WT,IT}) where {ID,T,WT,IT}
    x.state_syn[] = zero(IT)
    x.state_seg[] = 0
    x.state[] = false

    foreach(reset!, x.synapses)
    foreach(reset!, x.next_upstream)
end

function reset!(x::Segment{ID,T,WT,IT}) where {ID,T,WT,IT}
    x.state_syn[] = zero(IT)
    x.state_seg[] = 0
    x.state[] = false
    x.last_activated[]=zero(T)

    foreach(reset!, x.next_upstream)
end

function reset!(x::Input{ID,T,WT,IT}) where {ID,T,WT,IT}
    foreach(reset!, x.synapses)
end

function reset!(x::Output{ID,T,WT,IT}) where {ID,T,WT,IT}
    x.state_syn[] = zero(IT)
end

function reset!(x::Synapse{ID,T,WT,IT}) where {ID,T,WT,IT}
    x.state[]=false
    x.magnitude[]=zero(IT)
end

"""Turn all upstream branches on."""
function backprop_on!(obj::Segment, now, logger!)
    for s_up in obj.next_upstream
        backprop_on!(s_up, now, logger!)
    end

    # this segment is now clamped to the downstream and all upstream branches are on
    obj.state_seg[] = length(obj.next_upstream)
    obj.state[] = true
    obj.last_activated[] = now
    logger!(now, :backprop_plateau_starts, obj.id, obj.state[])
    return nothing
end

"""Turn all upstream branches off"""
function backprop_off!(obj::Segment, now, logger!)
    for s_up in obj.next_upstream
        backprop_off!(s_up, now, logger!)
    end

    # this segment is now off all so are all upstream branches
    obj.state_seg[] = 0
    obj.state[] = false
    logger!(now, :backprop_plateau_ends, obj.id, obj.state[])
    return nothing
end

"""Check if this segment was just turned on; if so, backpropagate!"""
function maybe_on!(obj::Segment, now, queue!, logger!)
    # if the segment is currently off, but the plateau conditions are satisfied, turn on
    return if ~obj.state[] && obj.state_syn[] >= obj.θ_syn && (isempty(obj.next_upstream) || obj.state_seg[] >= obj.θ_seg)
        @debug "$(now): Triggered segment $(obj.id) and it turned on!"
        # propagate to the upstream segments
        backprop_on!(obj, now, logger!)
        logger!(now, :plateau_starts, obj.id, obj.state[])

        # turning on this segment might have also turned on the next_downstream segment
        obj.next_downstream.state_seg[] += 1
        cascaded = maybe_on!(obj.next_downstream, now, queue!, logger!)

        # The last segment turns the lights off!
        if ~cascaded || isa(obj.next_downstream, Neuron)
            queue!(Event(:plateau_ends, now, now+obj.plateau_duration, obj))
        end
        true
    else
        @debug "$(now): Triggered segment $(obj.id), but it didn't turn on!"
        false
    end
end

"""Check if this segment should switch off, since its plateau has timed out"""
function maybe_off!(obj::Segment, now, queue!, logger!)
    # if the segment is currently on and has no reason to stay on, turn off
    if obj.state[] && ~(obj.state_syn[] >= obj.θ_syn && (isempty(obj.next_upstream) || obj.state_seg[] >= obj.θ_seg))
        @debug "$(now): Triggered segment $(obj.id) and it turned off!"
        # propagate this info upwards
        backprop_off!(obj, now, logger!)
        logger!(now, :plateau_ends, obj.id, obj.state[])

        # update next_downstream segment
        obj.next_downstream.state_seg[] -= 1
        # turning off might have withdrawn support for the downstream segment (e.g. if this segment was inhibited via a synapse)
        if isa(obj.next_downstream, Segment)
            maybe_off!(obj.next_downstream, now, queue!, logger!)
        end
    else
        @debug "$(now): Triggered segment $(obj.id), but it didn't turn off!"
    end
    return nothing
end


"""Check if this Input was triggered to spike"""
function on!(obj::Input, now, queue!, logger!)
    @debug "$(now): Triggered input $(obj.id) to fire!"
    for s in obj.synapses
        queue!(Event(:epsp_starts, now, now+s.delay, s))
    end
    return nothing
end

"""Check if this neuron was triggered to spike"""
function maybe_on!(obj::Neuron, now, queue!, logger!)
    if ~obj.state[]  && obj.state_syn[] >= obj.θ_syn && (isempty(obj.next_upstream) || obj.state_seg[] >= obj.θ_seg)
        @debug "$(now): Triggered neuron $(obj.id) and it fired a spike!"
        obj.state[] == true
        logger!(now, :spikes, obj.id, obj.state[])

        # trigger all synapses
        for s in obj.synapses
            queue!(Event(:epsp_starts, now, now+s.delay, s))
        end

        # don't forget to recover from refractory period
        queue!(Event(:refractory_period_ends, now, now+obj.refractory_duration, obj))
    else
        @debug "$(now): Triggered neuron $(obj.id), but didn't fire!"
    end
    return false
end

"""Check if this neuron was re-triggered to spike after refractoriness"""
function maybe_off!(obj::Neuron, now, queue!, logger!)
    @debug "$(now): Neuron $(obj.id) came out of refractoriness!"
    obj.state[] = false
    logger!(now, :refractory_period_ends, obj.id, obj.state[])

    # check if the neuron should spike again, right away
    maybe_on!(obj::Neuron, now, queue!, logger!)
end



"""Check if an incoming spike should trigger an EPSP"""
function on!(obj::Synapse, now, queue!, logger!)
    if ~obj.state[]
        @debug "$(now): Triggered synapse $(obj.id) and started an EPSP!"
        obj.state[] = true
        # set the synapse's state for this spike
        obj.magnitude[] = sample_spike_magnitude(obj.weight)
        # inform the target segment about this new EPSP
        obj.target.state_syn[] += obj.magnitude[]
        logger!(now, :epsp_starts, obj.id, obj.state[])

        # don't forget to turn off EPSP
        queue!(Event(:epsp_ends, now, now+obj.spike_duration, obj))

        # if the spike was excitatory this EPSP might have triggered a plateau in the target
        # else if it was inhibitory this EPSP may have destroyed any ongoing plateau
        if obj.magnitude[] > zero(obj.magnitude[])
            maybe_on!(obj.target, now,  queue!, logger!)
        elseif obj.magnitude[] < zero(obj.magnitude[])
            maybe_off!(obj.target, now,  queue!, logger!)
        end
    else
        @debug "$(now): Triggered synapse $(obj.id), but didn't start an EPSP!"
    end
    return nothing
end

"""Turn off the EPSP"""
function off!(obj::Synapse, now, queue!, logger!)
    # only update if the synapse isn't already off (shouldn't happen!)
    if obj.state[]
        @debug "$(now): Triggered synapse $(obj.id) and turned EPSP off!"
        # inform the target, that the EPSP is over
        obj.target.state_syn[] -= obj.magnitude[]

        # if the spike was inhibitory, this EPSP's end may trigger a rebound spike
        if obj.magnitude[] < zero(obj.magnitude[])
            maybe_on!(obj.target, now,  queue!, logger!)
        end

        # reset the synapse's state
        obj.magnitude[] = zero(obj.magnitude[])
        obj.state[] = false
        logger!(now, :epsp_ends, obj.id, obj.state[])
        
    else
        @debug "$(now): Triggered synapse $(obj.id), but didn't turn EPSP off!"
    end
    return nothing
end

"""Trigger output"""
function maybe_on!(obj::Output, now, queue!, logger!)
    @debug "$(now): Triggered output $(obj.id)!"
    logger!(now, :spikes, obj.id, true)
    return nothing
end


################################################################################
## Logging                                                                    ##
################################################################################

struct Logger
    data::DataFrame
    filter::Function

    function Logger(net::Network{ID,T,WT,IT}; filter=(t,tp,id,x)->true, DT=Union{Bool,IT}) where {ID,T,WT,IT}
        data = DataFrame(:t=>T[], :event=>Symbol[], :object=>ID[], :state=>DT[])
        new(data, filter)
    end
end

"""Log state of 'Output' object at each event"""
function (l::Logger)(args...)
    if getfield(l, :filter)(args...)
        push!(getfield(l,:data), args)
    end
end

Base.getproperty(l::Logger, sym::Symbol) = getproperty(getfield(l,:data),sym)
Base.propertynames(l::Logger) = propertynames(getfield(l,:data))

################################################################################
## pretty printing                                                            ##
################################################################################

Base.show(io::IO, x::Logger)   = Base.show(io, getfield(x,:data))
Base.show(io::IO, x::Network)  = print(io, "Network with $(length(x.inputs)) inputs and $(length(x.neurons)) neurons")
Base.show(io::IO, x::Neuron)   = print(io, "Neuron '$(x.id)' with $(length(x.next_upstream)) child-segments and $(length(x.synapses)) outgoing synapses")
Base.show(io::IO, x::Input)    = print(io, "Input '$(x.id)' with $(length(x.synapses)) outgoing synapses")
Base.show(io::IO, x::Output)   = print(io, "Output '$(x.id)'")
Base.show(io::IO, x::Segment)  = print(io, "Segment '$(x.id)' with $(length(x.next_upstream)) child-segments")
Base.show(io::IO, x::Synapse)  = print(io, "Synapse '$(x.id)' (connects to $(x.target.id))")
