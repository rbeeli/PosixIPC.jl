module Queues

include("interface.jl")
include("Message.jl")
include("SPSC/module.jl")
include("PubSub/module.jl")

# export all
for n in names(@__MODULE__; all = true)
	if Base.isidentifier(n) && n ∉ (Symbol(@__MODULE__), :eval, :include) && !startswith(string(n), "_")
		@eval export $n
	end
end

end # module
