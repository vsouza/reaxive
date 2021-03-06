defmodule Reaxive.Rx.Impl do

	use GenServer
	require Logger

	@moduledoc """
	Implements the Rx protocols and handles the contract. This module is internally used
	as the workhorse for most Rx combinators. However, any user should not rely on inner
	workings but use only `Reaxive.Rx.`, since this module is subject to change. 

	There are several issues with this implementation, in particular from an idiomatic  
	point of view and it is too complicated. 
	"""

	@typedoc """
	Internal message for propagating events.
	"""
	@type rx_propagate :: {:on_next, term} | {:on_error, term} | {:on_completed, nil | pid}
	@typedoc """
	Tags for interacting between reduce-function and its reducers. They have the following
	implications:

	* `:cont`: continue with the iteration and send the current value to subscribers
	* `:ignore`: continue the iteration, but do not set anything to subscribers (i.e. ignore the value)
	* `:halt`: stop the iteration and send the current value to subscribers
	"""
	@type reduce_tag :: :cont | :halt | :ignore
	@typedoc "Return value of reducers"
	@type reducer :: {reduce_tag, rx_propagate, term}

	@type t :: %__MODULE__{}

	defstruct name: nil, # might be handy to identify the Rx?
		active: true, # if false, then an error has occurred or the calculation is completed
		subscribers: [], # all interested observers
		sources: [], # list of disposables
		action: nil, # the function to be applied to the values
		options: [], #  behavior options,
		queue: nil, # outbound queue before any subscriber is available
		on_run: nil, # function called at run
		accu: [] # accumulator

	defmodule Rx_t do
		@moduledoc """
		Encapsulates a `Rx_Impl` process instance 
		"""
		defstruct pid: nil 
		
		defimpl Observer do
			def on_next(observer, value), do:      Reaxive.Rx.Impl.on_next(observer, value)
			def on_error(observer, exception), do: Reaxive.Rx.Impl.on_error(observer, exception)
			def on_completed(observer, observable), do:        Reaxive.Rx.Impl.on_completed(observer, observable)
		end

		defimpl Observable do
			def subscribe(observable, observer), do: Reaxive.Rx.Impl.subscribe(observable, observer)
		end
	
		defimpl Runnable do
			def run(rx) do 
				Reaxive.Rx.Impl.run(rx)
				rx
			end
		end
	end

	@doc """
	Starts the Rx Impl. If `auto_stop` is true, the `Impl` finishes after completion or
	after an error or after unsubscribing the last subscriber.
	"""
	@spec start() :: {:ok, Observable.t}
	def start(), do: start(nil, [auto_stop: true])
	@spec start(nil | String.t, Keyword.t) :: {:ok, Observable.t}
	def start(name, options) do
		{:ok, pid} = GenServer.start(__MODULE__, [name, options])
		{:ok, %Rx_t{pid: pid}}
	end
	def init([name, options]) do
		s = %__MODULE__{name: name, options: options}
		# Logger.info "init - state = #{inspect s}"
		if Keyword.get(options, :queue, false), do:
			s = %{s | queue: :queue.new()}
		{:ok, s}
	end

	@doc """
	Subscribes a new observer. Returns a function for unsubscribing the observer.

	Fails grafecully with an `on_error` message to the observer, if the
	observable is not or no longer available. In this case, an do-nothing unsubciption
	functions is returned (since no subscription has occured in the first place).

	# TODO:
	The typing is not correct, we need to return subscriptions, also in the error case!
	"""
	@spec subscribe(Observable.t, Observer.t) :: {Observable.t, (() -> :ok)}
	def subscribe(%Rx_t{pid: pid} = observable, observer) do
		{:ok, sub} = Reaxive.Subscription.start_link(fn() -> 
			unsubscribe(observable, observer) end)
		try do
			:ok = GenServer.cast(pid, {:subscribe, observer})
			#{observable, dispose_fun}
			{observable, sub}
		catch
			:exit, {fail, {GenServer, :call, _}} when fail in [:normal, :noproc] ->
				Logger.debug "subscribe failed because observable #{inspect observable} does not exist anymore"
				Logger.debug Exception.format_stacktrace()
				Observer.on_error(observer, :subscribe_failed)
				{observable, fn() -> :ok end}
		end
	end

	@doc """
	Unsubscribes an `observer` from the event sequence. If the event sequence 
	does not exist any longer, the caller must handle any problems. Usually, this 
	error handling is done within a subscription such that a "real" client has not
	consider this.
	"""
	def unsubscribe(%Rx_t{pid: pid} = _observable, observer), do:
		GenServer.call(pid, {:unsubscribe, observer})

	@doc """
	Sets the disposable event sequence `source`. This is needed for proper unsubscribing
	from the `source` when terminating the sequence.
	"""
	def source(%Rx_t{pid: pid} = _observable, disposable) do
		try do
			GenServer.cast(pid, {:source, disposable})
		catch
			:exit, {fail, {GenServer, :call, _}} when fail in [:normal, :noproc] ->
				# Logger.debug "source failed because observable does not exist anymore"
				Subscription.unsubscribe disposable
		end
	end

	@doc """
	This function sets the internal action on received events before the event is
	propagated to the subscribers. An initial accumulator value can also be provided.
	"""
	def fun(%Rx_t{pid: pid} = _observable, fun, acc \\ []), do:
		GenServer.call(pid, {:fun, fun, acc})

	@doc """
	Composes the internal action on received events with the given `fun`. The
	initial function to compose with is the identity function.
	"""
	def compose(%Rx_t{pid: pid} = observable, {fun, acc}) do
		:ok = GenServer.call(pid, {:compose, fun, acc})
		observable
	end
	def compose(%Rx_t{pid: pid} = _observable, fun, acc), do:
		GenServer.call(pid, {:compose, fun, acc})

	@doc "All subscribers of Rx. Useful for debugging."
	def subscribers(%Rx_t{pid: pid} = _observable), do: GenServer.call(pid, :subscribers)

	@doc "All sources of Rx. Useful for debugging."
	def get_sources(%Rx_t{pid: pid} = _observable), do: GenServer.call(pid, :get_sources)

	@doc "Sets the on_run function, which is called for the first subscription."
	def on_run(%Rx_t{pid: pid} = _observable, on_run), do:
		GenServer.call(pid, {:on_run, on_run})

	@doc "Starts the event sequence"
	def run(%Rx_t{pid: pid} = _observable), do:
		GenServer.cast(pid, {:run})

	@doc "Sets the auto_stop flag for the running Rx."
	def set_auto_stop(%Rx_t{pid: pid} = _observable, auto_stop), do:
		GenServer.call(pid, {:set_auto_stop, auto_stop})

	@doc "All request-reply calls for setting up the Rx."
	def handle_call({:unsubscribe, observer}, _from, %__MODULE__{subscribers: sub} = state) do
		new_sub = List.delete(sub, observer)
		new_state = %__MODULE__{state | subscribers: new_sub}
		case terminate?(new_state) do
			true  -> {:stop, :normal, new_state}
			false -> {:reply, :ok, new_state}
		end
	end
	def handle_call({:fun, fun, acc}, _from, %__MODULE__{action: nil}= state), do:
		{:reply, :ok, %__MODULE__{state | action: fun, accu: acc}}
	def handle_call({:compose, fun, acc}, _from, %__MODULE__{action: nil, accu: []}= state), do:
		{:reply, :ok, %__MODULE__{state | action: fun, accu: [acc]}}
	def handle_call({:compose, fun, acc}, _from, %__MODULE__{action: g, accu: accu}= state), do:
		{:reply, :ok, %__MODULE__{state | action: fn(x) -> fun . (g . (x)) end, accu: :lists.append(accu, [acc])}}
	def handle_call(:subscribers, _from, %__MODULE__{subscribers: sub} = s), do: {:reply, sub, s}
	def handle_call(:get_sources, _from, %__MODULE__{sources: src} = s), do:
		{:reply, src, s}
	def handle_call({:on_run, fun}, _from, %__MODULE__{on_run: nil}= state), do:
		{:reply, :ok, %__MODULE__{state | on_run: fun}}
	def handle_call({:set_auto_stop, stop_it}, _from, %__MODULE__{options: options}= state), do:
		%__MODULE__{state | 
			options: options |> Keyword.update(:auto_stop, stop_it, fn(_) -> stop_it end)} |>
			terminate_if_required(:ok)

	@doc "Process the next value"
	def on_next(%Rx_t{pid: pid} = _observer, value) do
		# Logger.debug "Sending on_next(#{inspect value}) to #{inspect pid}"
		:ok = GenServer.cast(pid, {:on_next, value})
	end

	@doc "The last regular message"
	def on_completed(%Rx_t{pid: pid} = _observer, observable), do:
		:ok = GenServer.cast(pid, {:on_completed, observable})

	@doc "An error has occured, the pipeline will be aborted."
	def on_error(%Rx_t{pid: pid} = _observer, exception), do:
		:ok = GenServer.cast(pid, {:on_error, exception})

	@doc "Asynchronous callback. Used for processing values and subscription."
	def handle_cast({:run}, %__MODULE__{active: true}= state), do:
		{:noreply, do_run(state)}
	def handle_cast({:run}, %__MODULE__{active: false}= state), do:
		{:noreply, state}
	def handle_cast({:subscribe, observer},	%__MODULE__{subscribers: []} = state), do:
		do_subscribe(state, observer)
	def handle_cast({:subscribe, observer}, %__MODULE__{} = state), do:
		do_subscribe(state, observer)
	def handle_cast({:source, disposable}, %__MODULE__{sources: []}= state) when is_list(disposable), do:
		{:noreply, %__MODULE__{state | sources: disposable}}
	def handle_cast({:source, disposable}, %__MODULE__{sources: src}= state) when is_list(disposable), do:
		{:noreply, %__MODULE__{state | sources: disposable ++ src}}
	def handle_cast({:source, disposable}, %__MODULE__{sources: src}= state), do:
		{:noreply, %__MODULE__{state | sources: [disposable | src]}}
	def handle_cast({_tag, _v} = value, state) do
		# Logger.debug "RxImpl #{inspect self} got message #{inspect value} in state #{inspect state}"
		handle_event(state, value) |> terminate_if_required
	end

	def terminate_if_required(state, return) do
		case terminate_if_required(state) do
			{:noreply, state} -> {:reply, return, state}
			any -> any
		end
	end
	def terminate_if_required(state) do
		if terminate?(state) do
			%__MODULE__{active: active} = state
			if active, do: emit(state, {:on_completed, nil})
			#Logger.debug "Stop in #{inspect self}, because terminate required at state #{inspect state}"
			{:stop, :normal, state}
		else
			#Logger.debug "NO Stop in #{inspect self}, at state #{inspect state}"
			{:noreply, state}
		end
	end

	@doc """
	Internal function to handles the various events, in particular disconnects
	the source which is sending a `on_completed`.
	"""
	@spec handle_event(t, rx_propagate) :: t
	def handle_event(%__MODULE__{} = state, _e = {:on_completed, src}) do
		# Logger.debug "#{inspect self} got an #{inspect e} in state #{inspect state}"
		state |>
		 	disconnect_source(src) |>
		 	# IO.inspect |> 
			handle_value({:on_completed, nil})
	end
	def handle_event(%__MODULE__{} = state, event), do:	handle_value(state, event)

	@doc """
	Internal function to handle new values, errors or completions. If `state.action` is
	`:nil`, the value is propagated without any modification.
	"""
	@spec handle_value(t, rx_propagate) :: t
	def handle_value(%__MODULE__{active: true} = state, e = {:on_error, _exception}) do
		# Logger.debug "got on_error #{inspect e} ==> disconnect all: #{inspect state}"
		notify({:cont, e}, state) |> disconnect_all()
	end
	def handle_value(%__MODULE__{active: true, action: fun, accu: accu} = state, value) do
		try do
			# Logger.debug "Handle_value with v=#{inspect value} and #{inspect state}"
			{tag, new_v, new_accu} = case do_action(fun, value, accu, []) do
				{{:cont, {_tag, _val} = ev}, _acc, new_acc} -> {:cont, ev, new_acc}
				{{tag, val}, _acc, new_acc} -> {:cont, {tag, val}, new_acc}
				{tag, val, _acc, new_acc} -> {tag, val, new_acc}
			end
			new_state = %__MODULE__{
				notify({tag, new_v}, state) |	accu: :lists.reverse(new_accu)}
			case tag do
				:halt -> disconnect_all(new_state)
				_ -> new_state
			end
		catch
			what, message ->
				#  Logger.error "Got exception: #{inspect what}, #{inspect message} \n" <>
				# 	"with value #{inspect value} in state #{inspect state}\n" <>
				# 	Exception.format(what, message)
				handle_value(state, {:on_error, {what, message}})
		end
	end
	def handle_value(%__MODULE__{active: false} = state, _value), do: state

	@doc "Internal function calculating the new value"
	@spec do_action(nil | (... -> any), rx_propagate, any, any) ::
		{ :halt | :cont, rx_propagate, any, any} | {rx_propagate, any, any}
	def do_action(nil, event = {:on_completed, nil}, _accu, new_accu), do:
		{:halt, event, [], new_accu}
	def do_action(nil, event, _accu, new_accu), do: {:cont, event, [], new_accu}
	def do_action(fun, event, accu, new_accu) when is_function(fun, 1),
		do: fun . ({event, accu, new_accu})

	@doc "Internal callback function at termination for clearing resources"
	def terminate(_reason, _state = %__MODULE__{sources: src}) do
		# Logger.info("Terminating #{inspect self} for reason #{inspect reason} in state #{inspect state}")
		src |> Enum.each(fn({_pid, sub}) -> sub |> Subscription.unsubscribe() end)
	end


	@doc "Internal function to disconnect from the sources"
	@spec disconnect_all(t) :: t
	def disconnect_all(%__MODULE__{active: true, sources: src} = state) do
		# Logger.info("disconnecting all from #{inspect state}")
		# src |> Enum.each fn({_id, disp}) -> Subscription.unsubscribe(disp) end
		src |> Enum.each(fn({_pid, sub}) -> sub |> Subscription.unsubscribe() end)
		%__MODULE__{state | active: false, subscribers: []}
	end
	# disconnecting from a disconnected state does not change anything
	def disconnect_all(%__MODULE__{active: false, subscribers: []} = s), do: s

	@doc """
	Internal function for disconnecting a single source. This function
	does not change anything beyond the `sources` field, in particular
	no decision about inactivating or even stopping the event sequence
	is taken.
	"""
	@spec disconnect_source(%__MODULE__{}, any) :: %__MODULE__{}
	def disconnect_source(%__MODULE__{sources: src} = state, src_id) do
		#Logger.debug("disconnecting #{inspect src_id} from Rx #{inspect self}=#{inspect state}")
		new_src = src 
			|> Enum.map(fn 	(sub ={%Reaxive.Rx.Impl.Rx_t{pid: pid}, s}) ->
								if pid == src_id, do: Subscription.unsubscribe(s) 
								sub	
							(sub = {id, s}) -> 
								if id == src_id, do: Subscription.unsubscribe(s) 
								sub	
						end)
			|> Enum.reject(fn
							({%Reaxive.Rx.Impl.Rx_t{pid: pid}, _}) -> pid == src_id 
							({id, _}) -> id == src_id 
						end)
		if (new_src == src), do: Logger.error "disconnecting from unknown src = #{inspect src_id}"
		%__MODULE__{state | sources: new_src }
	end

	@doc "Internal function for subscribing a new `observer`"
	def do_subscribe(%__MODULE__{subscribers: sub}= state, observer) do
		# Logger.info "RxImpl #{inspect self} subscribes to #{inspect observer} in state #{inspect state}"
		{:noreply,%__MODULE__{state | subscribers: [observer | sub]}}
	end

	@doc "run the sequence by calling `run` on all source and call the `on_run` function."
	def do_run(%__MODULE__{sources: src, on_run: nil} = state) do
		# Logger.debug "do_run on #{inspect state}"
		src |> Enum.each(fn {id, _s} -> Runnable.run(id) end)
		state
	end
	def do_run(%__MODULE__{sources: src, on_run: runner} = state) do
		# Logger.debug "do_run on #{inspect state}"
		runner.()
		src |> Enum.each(fn {id, _s} -> Runnable.run(id) end)
		state
	end

	@doc "Internal function to notify subscribers, knows about ignoring notifies."
	@spec notify({reduce_tag, rx_propagate}, t) :: t
	def notify({:ignore, _}, state), do: state
	def notify({:cont, {:ignore, _}}, state), do: state
	def notify({:cont, ev = {:on_next, _value}}, s = %__MODULE__{}), do: emit(s, ev)
	def notify({:cont, ev = {:on_error, _exc}}, s = %__MODULE__{}), do: emit(s, ev)
	def notify({:cont, ev = {:on_completed, nil}}, %__MODULE__{} = state) do
		# Logger.info(":cont call on completed in #{inspect self}: #{inspect state} ")
		emit(state, ev)
	end
	def notify({:cont, {:on_completed, value}}, s = %__MODULE__{}), do:
		s |> emit({:on_next, value}) |> emit({:on_completed, self})
	def notify({:halt, {:on_next, value}}, s = %__MODULE__{}), do:
		s |> emit({:on_next, value}) |> emit({:on_completed, self})
	def notify({:halt, {:on_completed, nil}}, %__MODULE__{} = state) do
		# Logger.info(":halt call on completed in #{inspect self}: #{inspect state} ")
		state |> emit({:on_completed, self})
	end

	@doc "Either emits a value or puts it into the queue"
	@spec emit(t, rx_propagate) :: t
	def emit(s = %__MODULE__{queue: nil, subscribers: sub}, {:on_next, value}) do
		sub |> Enum.each(&Observer.on_next(&1, value))
		s
	end
	def emit(s = %__MODULE__{queue: nil, subscribers: sub}, {:on_completed, _value}) do
		sub |> Enum.each(&Observer.on_completed(&1, self))
		s
	end
	def emit(s = %__MODULE__{queue: nil, subscribers: sub}, {:on_error, value}) do
		sub |> Enum.each(&Observer.on_error(&1, value))
		s
	end
	def emit(s = %__MODULE__{queue: q, subscribers: []}, event) do
		%__MODULE__{s | queue: :queue.in(event, q)}
	end
	def emit(s = %__MODULE__{queue: q}, ev) do
		events = :queue.to_list(q)
		new_s = %__MODULE__{s | queue: nil}
		events |>
			# emit all enqued events
			Enum.reduce(new_s, fn(state, e) -> emit(state, e) end) |>
			# and finally the new event
			emit(ev)
	end

	@doc "Internal predicate to check if we 
	terminate ourselves."
	def terminate?(%__MODULE__{options: options, sources: []}) do
		Keyword.get(options, :auto_stop, false)
	end
	def terminate?(%__MODULE__{options: options, subscribers: []}) do
		Keyword.get(options, :auto_stop, false)
	end
	def terminate?(%__MODULE__{options: options, active: false}) do
		Keyword.get(options, :auto_stop, false)
	end
	def terminate?(%__MODULE__{}), do: false


	defimpl Observer, for: Function do
		def on_next(observer, value), do: observer.(:on_next, value)
		def on_error(observer, exception), do: observer.(:on_error, exception)
		def on_completed(observer, observable), do: observer.(:on_completed, observable)
	end
end
