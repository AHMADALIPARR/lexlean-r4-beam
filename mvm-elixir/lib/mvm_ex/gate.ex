defmodule MvmEx.Gate do
  @moduledoc """
  Host-side command gate, ported from mvm's `mvm_core::crypto::command_gate`.

  Every command the guest asks to run is evaluated against a blocklist
  before it executes. Literal patterns match as substrings; patterns
  containing `*` or `?` match as globs. Decisions, in precedence order:
  `:blocked` beats `:requires_approval` beats `:allow` (with logged
  matches reported alongside the allow). The default blocklist below is
  ported verbatim from the Rust `default_blocklist()`.
  """

  @type action :: :block | :require_approval | :log
  @type severity :: :critical | :high | :medium | :low
  @type entry :: %{pattern: String.t(), category: String.t(), severity: severity(), action: action()}
  @type decision ::
          {:allow, [String.t()]}
          | {:blocked, String.t(), String.t()}
          | {:requires_approval, String.t(), String.t()}

  @spec default_blocklist() :: [entry()]
  def default_blocklist do
    [
      # Destructive commands
      %{pattern: "rm -rf /", category: "destructive", severity: :critical, action: :block},
      %{pattern: "mkfs", category: "destructive", severity: :critical, action: :block},
      %{pattern: "dd if=/dev/zero", category: "destructive", severity: :critical, action: :block},
      %{pattern: "> /dev/sda", category: "destructive", severity: :critical, action: :block},
      %{pattern: ":(){ :|:& };:", category: "destructive", severity: :critical, action: :block},
      # Privilege escalation
      %{pattern: "nsenter", category: "privilege_escalation", severity: :high, action: :block},
      %{pattern: "unshare", category: "privilege_escalation", severity: :high, action: :require_approval},
      %{pattern: "chroot", category: "privilege_escalation", severity: :high, action: :require_approval},
      # Sensitive file access
      %{pattern: "/etc/shadow", category: "sensitive_file", severity: :high, action: :block},
      %{pattern: ".ssh/id_rsa", category: "sensitive_file", severity: :high, action: :block},
      %{pattern: ".aws/credentials", category: "sensitive_file", severity: :high, action: :block},
      # VM escape vectors
      %{pattern: "/dev/kvm", category: "vm_escape", severity: :critical, action: :block},
      %{pattern: "release_agent", category: "vm_escape", severity: :critical, action: :block}
    ]
  end

  @spec new([entry()]) :: [entry()]
  def new(blocklist \\ default_blocklist()), do: blocklist

  @spec evaluate([entry()], String.t()) :: decision()
  def evaluate(blocklist, command) when is_list(blocklist) and is_binary(command) do
    {literals, globs} =
      Enum.split_with(blocklist, fn e -> not String.contains?(e.pattern, ["*", "?"]) end)

    {pending, logs} =
      Enum.reduce(literals, {nil, []}, fn entry, {pending, logs} ->
        if String.contains?(command, entry.pattern) do
          case entry.action do
            :block -> throw({:blocked, entry.pattern, entry.category})
            :require_approval -> {pending || {entry.pattern, entry.category}, logs}
            :log -> {pending, [entry.pattern | logs]}
          end
        else
          {pending, logs}
        end
      end)

    {pending, logs} =
      Enum.reduce(globs, {pending, logs}, fn entry, {pending, logs} ->
        if glob_match?(entry.pattern, command) do
          case entry.action do
            :block -> throw({:blocked, entry.pattern, entry.category})
            :require_approval -> {pending || {entry.pattern, entry.category}, logs}
            :log -> {pending, [entry.pattern | logs]}
          end
        else
          {pending, logs}
        end
      end)

    case pending do
      {pattern, category} -> {:requires_approval, pattern, category}
      nil -> {:allow, Enum.reverse(logs)}
    end
  catch
    {:blocked, pattern, category} -> {:blocked, pattern, category}
  end

  @spec evaluate_dev_mode([entry()], String.t()) :: decision()
  def evaluate_dev_mode(blocklist, command) do
    case evaluate(blocklist, command) do
      {:requires_approval, pattern, _category} -> {:allow, ["dev-mode auto-approved: #{pattern}"]}
      other -> other
    end
  end

  @doc """
  Glob match: `*` matches any run of characters, `?` matches exactly one.
  The pattern must match the whole command string.
  """
  @spec glob_match?(String.t(), String.t()) :: boolean()
  def glob_match?(pattern, text) do
    match_glob(String.graphemes(pattern), String.graphemes(text))
  end

  defp match_glob([], []), do: true
  defp match_glob([], _), do: false
  defp match_glob(["*" | pr], text), do: match_star(pr, text)
  defp match_glob(["?" | pr], [_ | tr]), do: match_glob(pr, tr)
  defp match_glob(["?" | _], []), do: false
  defp match_glob([p | pr], [p | tr]), do: match_glob(pr, tr)
  defp match_glob(_, _), do: false

  defp match_star(pr, []), do: match_glob(pr, [])
  defp match_star(pr, [_ | _] = text), do: match_glob(pr, text) or match_star(pr, tl(text))
end
