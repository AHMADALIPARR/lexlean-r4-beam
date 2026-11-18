defmodule MvmEx.CLI do
  @moduledoc """
  `mvmctl` escript — the command line for the Elixir microVM port.

  Commands (mirroring upstream `mvmctl` where the backend allows):
  - `doctor` — host checks: /dev/kvm, OTP/Elixir, gpu root, packs
  - `weights` — pack inventory from the manifests
  - `weights verify <pack>` — SHA-256-verify one pack's shards
  - `weights stitch-v8 <out>` — reassemble the v8 .uorlut, check hash
  - `machine run --image <img> -- <command>` — plan, sign (ephemeral
    key), audit, boot a software-backend VM, run, print output
  - `pool warm <n> --image <img>` — prepare n standby VMs
  - `audit verify` — verify the hash-chained audit log
  """

  alias MvmEx.{Audit, Instance, Plan, Pool, VM, Weights}

  @spec main([String.t()]) :: no_return()
  def main(args) do
    code =
      case args do
        ["doctor"] -> doctor()
        ["weights"] -> weights()
        ["weights", "verify", pack] -> weights_verify(pack)
        ["weights", "stitch-v8", out] -> weights_stitch_v8(out)
        ["machine", "run" | rest] -> machine_run(rest)
        ["pool", "warm", n | rest] -> pool_warm(n, rest)
        ["audit", "verify"] -> audit_verify()
        _ -> usage()
      end

    System.halt(code)
  end

  defp usage do
    IO.puts("""
    mvmctl (elixir port) — secure microVMs on the BEAM, software backend
    usage:
      mvmctl doctor
      mvmctl weights
      mvmctl weights verify <v8|v9|v10|v12_360m|v13_qwen3_0_6b|v13_qwen3_1_7b>
      mvmctl weights stitch-v8 <out.uorlut>
      mvmctl machine run --image <image> -- <command>
      mvmctl pool warm <n> --image <image>
      mvmctl audit verify
    """)

    2
  end

  defp data_dir, do: System.get_env("MVM_DATA_DIR", Path.join(System.tmp_dir!(), "mvm-ex"))
  defp audit_path, do: Path.join(data_dir(), "audit.log")

  defp doctor do
    IO.puts("mvmctl doctor")
    IO.puts("  backend: software (no hypervisor on this host)")
    IO.puts("  /dev/kvm: #{if MvmEx.kvm_available?(), do: "present", else: "absent — software backend only"}")
    IO.puts("  otp: #{:erlang.system_info(:otp_release)}  elixir: #{System.version()}")

    case Weights.gpu_root() do
      {:ok, root} ->
        IO.puts("  gpu root: #{root}")
        Enum.each(Weights.inventory(root), fn p ->
          IO.puts("  pack #{p["id"]}: #{p["source_model"]} — manifest=#{p["manifest_present"]} shards=#{p["shards_present_count"]}/#{p["shard_count"]}")
        end)

        0

      {:error, reason} ->
        IO.puts("  gpu root: MISSING (#{reason})")
        1
    end
  end

  defp weights do
    case Weights.gpu_root() do
      {:ok, root} ->
        Enum.each(Weights.inventory(root), fn p ->
          IO.puts("#{p["id"]}\t#{p["source_model"]}\t#{p["format"]}\t#{p["total_bytes"]} B\tshards #{p["shards_present_count"]}/#{p["shard_count"]} present")
        end)

        0

      {:error, reason} ->
        IO.puts("error: #{reason}")
        1
    end
  end

  defp weights_verify(pack) do
    with {:ok, root} <- Weights.gpu_root(),
         {:ok, result} <- Weights.verify_pack(root, pack) do
      IO.puts("pack #{pack}: #{result["ok"]}/#{result["total"]} shards ok")
      if result["missing"] != [], do: IO.puts("  missing: #{Enum.join(result["missing"], ", ")}")
      if result["bad"] != [], do: IO.puts("  BAD: #{Enum.join(result["bad"], ", ")}")
      if result["verified"], do: 0, else: 1
    else
      {:error, reason} -> IO.puts("error: #{reason}"); 1
    end
  end

  defp weights_stitch_v8(out) do
    with {:ok, root} <- Weights.gpu_root(),
         {:ok, result} <- Weights.stitch_v8(root, out) do
      IO.puts("stitched #{result["bytes"]} bytes -> #{out}")
      IO.puts("sha256: #{result["sha256"]}")
      IO.puts("match: #{result["match"]}")
      if result["match"], do: 0, else: 1
    else
      {:error, reason} -> IO.puts("error: #{reason}"); 1
    end
  end

  defp machine_run(rest) do
    {opts, cmd_parts, _} = OptionParser.parse(rest, strict: [image: :string])
    image = Keyword.get(opts, :image, "alpine")
    command = Enum.join(cmd_parts, " ")

    if command == "" do
      IO.puts("error: machine run needs a command after --")
      2
    else
      File.mkdir_p!(data_dir())
      {pub, priv} = :crypto.generate_key(:eddsa, :ed25519)
      id = "run-#{:erlang.unique_integer([:positive])}"

      with {:ok, plan} <-
             Plan.synthesize(%{"id" => id, "image" => image, "command" => command}),
           {:ok, signed} <- Plan.sign(plan, priv),
           true <- Plan.verify(signed, pub),
           {:ok, instance} <- Instance.new(%{"id" => id, "image" => image, "command" => command}),
           {:ok, pid} <- VM.start_link(instance, data_dir: data_dir(), audit_path: audit_path()),
           {:ok, result} <- VM.exec(pid, command) do
        Audit.append_to_file(audit_path(), "plan_signed", %{"plan" => id, "digest" => signed.digest})
        IO.write(result.output)
        VM.stop(pid)
        if result.exit_status == 0, do: 0, else: result.exit_status
      else
        {:error, reason} -> IO.puts("error: #{inspect(reason)}"); 1
        false -> IO.puts("error: plan signature did not verify"); 1
      end
    end
  end

  defp pool_warm(n, rest) do
    {opts, _, _} = OptionParser.parse(rest, strict: [image: :string])
    image = Keyword.get(opts, :image, "alpine")

    case Integer.parse(n) do
      {count, ""} when count >= 1 ->
        {:ok, _} = Application.ensure_all_started(:mvm_ex)

        case Pool.warm(image, count) do
          {:ok, ids} -> IO.puts("warmed #{length(ids)} standby(s): #{Enum.join(ids, ", ")}"); 0
          {:error, reason} -> IO.puts("error: #{reason}"); 1
        end

      _ ->
        IO.puts("error: pool warm needs a positive count")
        2
    end
  end

  defp audit_verify do
    with {:ok, entries} <- Audit.read_file(audit_path()),
         :ok <- Audit.verify(entries) do
      IO.puts("audit log ok: #{length(entries)} entries, chain verifies")
      0
    else
      {:error, reason} -> IO.puts("audit log FAILED: #{reason}"); 1
    end
  end
end
