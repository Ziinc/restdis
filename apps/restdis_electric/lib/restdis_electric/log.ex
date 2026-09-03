defmodule RestdisElectric.Log do
  @moduledoc """
  The append-only log of one shape.

  One process per active shape holds the log in memory, ordered by
  `t:RestdisElectric.Offset.t/0`, and durably persists it through
  `Restdis.Cache` under the `:shape` key scope. That scope makes shape logs
  inherit the tenant's existing per-tenant limits, metrics, and flush
  behaviour, and CubDB's on-disk storage is what lets a log survive a process
  or node restart.

  This module models the log as a single persisted value rather than the
  chunked, purpose-built file store the RFC describes for the eventual
  production storage engine: the durability and resume properties are the
  same, so the read and write API below is what later work should preserve
  when it replaces the storage underneath.
  """

  use GenServer

  alias Restdis.Cache
  alias Restdis.Cache.Key
  alias RestdisElectric.Limits
  alias RestdisElectric.Message
  alias RestdisElectric.Offset

  @type state :: %{
          tenant_id: String.t(),
          handle: String.t(),
          messages: [Message.t()],
          last_offset: Offset.t(),
          waiters: [{Offset.t(), GenServer.from()}]
        }

  @registry RestdisElectric.Log.Registry
  @supervisor RestdisElectric.Log.Supervisor

  @doc """
  Starts the log process for `tenant_id`/`handle`. Called only by the log's
  dynamic supervisor; use `ensure_started/2` elsewhere.
  """
  @spec start_link({String.t(), String.t()}) :: GenServer.on_start()
  def start_link({tenant_id, handle}) do
    GenServer.start_link(__MODULE__, {tenant_id, handle}, name: via(tenant_id, handle))
  end

  @doc false
  @spec child_spec({String.t(), String.t()}) :: Supervisor.child_spec()
  def child_spec(arg) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [arg]}, restart: :transient}
  end

  @doc """
  Starts (or reuses) the log process for `tenant_id`/`handle`, hydrating it
  from durable storage if a persisted log already exists.
  """
  @spec ensure_started(String.t(), String.t()) :: {:ok, pid()}
  def ensure_started(tenant_id, handle) do
    case Registry.lookup(@registry, {tenant_id, handle}) do
      [{pid, _}] ->
        {:ok, pid}

      [] ->
        case DynamicSupervisor.start_child(@supervisor, {__MODULE__, {tenant_id, handle}}) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
        end
    end
  end

  @doc """
  Appends `messages` to the log, in the order given. Callers must pass
  messages in increasing offset order; the log does not reorder them.

  Rejects the whole batch, leaving the log unchanged, if it would push the
  log past the tenant's configured `max_log_bytes` (`RestdisElectric.Limits`).
  """
  @spec append(String.t(), String.t(), [Message.t()]) :: :ok | {:error, Limits.limit_error()}
  def append(_tenant_id, _handle, []), do: :ok

  def append(tenant_id, handle, messages) when is_list(messages) do
    {:ok, pid} = ensure_started(tenant_id, handle)
    GenServer.call(pid, {:append, tenant_id, messages})
  end

  @doc """
  Reads every message strictly after `from_offset`, in order.
  """
  @spec read(String.t(), String.t(), Offset.t()) :: {:ok, [Message.t()], Offset.t()} | :error
  def read(tenant_id, handle, from_offset) do
    case Registry.lookup(@registry, {tenant_id, handle}) do
      [{pid, _}] ->
        call(pid, {tenant_id, handle}, {:read, from_offset})

      [] ->
        case load(tenant_id, handle) do
          {:ok, _messages, _last_offset} ->
            {:ok, pid} = ensure_started(tenant_id, handle)
            call(pid, {tenant_id, handle}, {:read, from_offset})

          :error ->
            :error
        end
    end
  end

  # A log process that died between lookup and call lost nothing: its state is on disk, so retrying works.
  defp call(pid, {tenant_id, handle} = shape, message, attempts \\ 5) do
    GenServer.call(pid, message)
  catch
    :exit, {reason, _} when reason in [:noproc, :normal, :killed, :shutdown] and attempts > 0 ->
      Process.sleep(10)
      {:ok, restarted} = ensure_started(tenant_id, handle)
      call(restarted, shape, message, attempts - 1)
  end

  @doc """
  Returns the offset of the last message written to the log, or `:beginning`
  if the log has no persisted state.
  """
  @spec last_offset(String.t(), String.t()) :: Offset.t()
  def last_offset(tenant_id, handle) do
    case read(tenant_id, handle, Offset.beginning()) do
      {:ok, _messages, last_offset} -> last_offset
      :error -> Offset.beginning()
    end
  end

  @doc """
  Blocks the caller until the log has a message strictly after
  `since_offset`, or until `timeout_ms` elapses. Returns immediately if the
  log already has such a message.
  """
  @spec await(String.t(), String.t(), Offset.t(), timeout()) ::
          {:ok, [Message.t()], Offset.t()} | :timeout
  def await(tenant_id, handle, since_offset, timeout_ms) do
    {:ok, pid} = ensure_started(tenant_id, handle)
    GenServer.call(pid, {:await, since_offset, timeout_ms}, timeout_ms + 1000)
  end

  @doc """
  Deletes the shape's log, in memory and on disk.
  """
  @spec delete(String.t(), String.t()) :: :ok
  def delete(tenant_id, handle) do
    case Registry.lookup(@registry, {tenant_id, handle}) do
      [{pid, _}] -> GenServer.stop(pid, :normal)
      [] -> :ok
    end

    Cache.delete(tenant_id, cache_key(handle))
  end

  @impl GenServer
  def init({tenant_id, handle}) do
    {messages, last_offset} =
      case load(tenant_id, handle) do
        {:ok, messages, last_offset} -> {messages, last_offset}
        :error -> {[], Offset.beginning()}
      end

    {:ok,
     %{
       tenant_id: tenant_id,
       handle: handle,
       messages: messages,
       last_offset: last_offset,
       waiters: []
     }}
  end

  @impl GenServer
  def handle_call({:append, tenant_id, new_messages}, _from, state) do
    current_bytes = :erlang.external_size(state.messages)
    additional_bytes = :erlang.external_size(new_messages)

    case Limits.check_log_bytes(tenant_id, current_bytes, additional_bytes) do
      :ok -> do_append(new_messages, state)
      {:error, _reason} = error -> {:reply, error, state}
    end
  end

  @impl GenServer
  def handle_call({:read, from_offset}, _from, state) do
    {:reply, {:ok, messages_after(state.messages, from_offset), state.last_offset}, state}
  end

  @impl GenServer
  def handle_call({:await, since_offset, timeout_ms}, from, state) do
    if Offset.before?(since_offset, state.last_offset) do
      {:reply, {:ok, messages_after(state.messages, since_offset), state.last_offset}, state}
    else
      Process.send_after(self(), {:await_timeout, from}, timeout_ms)
      {:noreply, %{state | waiters: [{since_offset, from} | state.waiters]}}
    end
  end

  @impl GenServer
  def handle_info({:await_timeout, from}, state) do
    case Enum.split_with(state.waiters, fn {_since, waiter} -> waiter == from end) do
      {[], _pending} ->
        {:noreply, state}

      {_expired, pending} ->
        GenServer.reply(from, :timeout)
        {:noreply, %{state | waiters: pending}}
    end
  end

  defp do_append(new_messages, state) do
    messages = state.messages ++ new_messages
    last_offset = Enum.reduce(new_messages, state.last_offset, &Offset.max(&1.offset, &2))
    persist(state.tenant_id, state.handle, messages, last_offset)

    {ready, pending} =
      Enum.split_with(state.waiters, fn {since, _from} -> Offset.before?(since, last_offset) end)

    Enum.each(ready, fn {since, from} ->
      GenServer.reply(from, {:ok, messages_after(messages, since), last_offset})
    end)

    {:reply, :ok, %{state | messages: messages, last_offset: last_offset, waiters: pending}}
  end

  defp messages_after(messages, from_offset) do
    Enum.filter(messages, fn message -> Offset.before?(from_offset, message.offset) end)
  end

  defp cache_key(handle), do: Key.build(:shape, handle, %{})

  defp persist(tenant_id, handle, messages, last_offset) do
    Cache.put(tenant_id, cache_key(handle), %{messages: messages, last_offset: last_offset},
      persist: true
    )
  end

  defp load(tenant_id, handle) do
    case Cache.get(tenant_id, cache_key(handle)) do
      {:ok, %{messages: messages, last_offset: last_offset}} -> {:ok, messages, last_offset}
      :miss -> :error
    end
  end

  defp via(tenant_id, handle), do: {:via, Registry, {@registry, {tenant_id, handle}}}
end
