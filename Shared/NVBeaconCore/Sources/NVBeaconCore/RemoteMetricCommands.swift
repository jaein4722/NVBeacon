import Foundation

public enum RemoteMetricCommands {
    public static let defaultGPUCommand = "nvidia-smi --query-gpu=index,name,uuid,utilization.gpu,memory.used,memory.total,temperature.gpu --format=csv,noheader,nounits"
    public static let legacyGPUCommand = "nvidia-smi --query-gpu=index,name,utilization.gpu,memory.used,memory.total,temperature.gpu --format=csv,noheader,nounits"
    public static let defaultMemoryCommand = "cat /proc/meminfo"
    public static let processDetailsCommand = "nvidia-smi --query-compute-apps=gpu_uuid,pid,process_name,used_gpu_memory --format=csv,noheader,nounits"
    public static let processSectionSeparator = "__GPUUSAGE_PROCESS_SECTION__"
    public static let psSectionSeparator = "__GPUUSAGE_PS_SECTION__"
    public static let hostSectionSeparator = "__NVBEACON_HOST_SECTION__"
    public static let memorySectionSeparator = "__NVBEACON_MEMORY_SECTION__"

    public static let cpuSectionSeparator = "__NVBEACON_CPU_SECTION__"
    public static let networkSectionSeparator = "__GPUUSAGE_NETWORK_SECTION__"

    public static let networkSampleCommand = """
    net_count=0
    for net_dir in /sys/class/net/*/; do
      net_name="${net_dir%/}"
      net_name="${net_name##*/}"
      if [ "$net_name" = "lo" ]; then continue; fi
      case "$net_name" in
        veth*|docker*|br-*|virbr*|vnet*|tap*|tun*|wg*|zt*|tailscale*|kube*|cni*|flannel*|cali*|dummy*|ifb*) continue ;;
      esac
      if [ -e "${net_dir}master" ]; then continue; fi
      net_rx="$(cat "${net_dir}statistics/rx_bytes" 2>/dev/null)" || continue
      net_tx="$(cat "${net_dir}statistics/tx_bytes" 2>/dev/null)" || continue
      printf '%s %s %s\\n' "$net_name" "$net_rx" "$net_tx"
      net_count=$((net_count + 1))
    done
    if [ "$net_count" -eq 0 ]; then
      sed 's/^[[:space:]]*//' /proc/net/dev 2>/dev/null | awk -F'[[:space:]:]+' 'NR > 2 { if ($1 == "lo") next; if ($1 ~ /^(veth|docker|br-|virbr|vnet|tap|tun|wg|zt|tailscale|kube|cni|flannel|cali|dummy|ifb)/) next; if ($10 == "") next; print $1, $2, $10 }' | while read -r net_name net_rx net_tx; do
        [ -e "/sys/class/net/$net_name/master" ] && continue
        printf '%s %s %s\\n' "$net_name" "$net_rx" "$net_tx"
      done
    fi
    """

    public static let defaultHostCommand = hostInfo()

    /// This entire script is editable per server. Collection switches are passed
    /// in the environment so custom scripts can honor the same item preferences.
    public static func hostInfo(memoryCommand: String = defaultMemoryCommand) -> String {
        let memory = memoryCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        let memoryQuery = memory.isEmpty ? defaultMemoryCommand : memory
        return """
        if [ "${NVBEACON_COLLECT_CPU:-1}" = "1" ]; then
          printf '\\n\(cpuSectionSeparator)\\n'
          awk '/^cpu / || /^btime / { print }' /proc/stat 2>/dev/null || true
        fi
        if [ "${NVBEACON_COLLECT_MEMORY:-1}" = "1" ]; then
          printf '\\n\(memorySectionSeparator)\\n'
          (
            \(memoryQuery)
          ) 2>/dev/null || true
        fi
        if [ "${NVBEACON_COLLECT_NETWORK:-1}" = "1" ]; then
          printf '\\n\(networkSectionSeparator)\\n'
          (
            \(networkSampleCommand)
          ) 2>/dev/null || true
        fi
        """
    }

    public static func resolveHostCommand(_ command: String?, legacyMemoryCommand: String = defaultMemoryCommand) -> String {
        guard let command else { return hostInfo(memoryCommand: legacyMemoryCommand) }
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? defaultHostCommand : trimmed
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// A copyable, executable single-line representation of a saved script.
    /// printf restores exact newlines/backslashes; the sentinel prevents command
    /// substitution from stripping trailing newlines. sh -c keeps stdin intact.
    public static func singleLineCommand(_ command: String) -> String {
        guard command.contains("\n") || command.contains("\r") else { return command }
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "/bin/sh -c 'exec /bin/sh -c \"${1%_}\"' sh \"$(printf '%b_' \(shellQuote(escaped)))\""
    }

    public static func summary(summaryCommand: String, memoryCommand: String = defaultMemoryCommand,
                               includesNetworkUsage: Bool = true, hostMetrics: HostMetricsOptions = .init(),
                               hostCommand: String? = nil) -> String {
        var command = """
        \(summaryCommand)
        printf '\\n\(processSectionSeparator)\\n'
        process_output="$(\(processDetailsCommand) 2>/dev/null || true)"
        printf '%s\\n' "$process_output" | while IFS=, read -r gpu_uuid pid pname used_mem; do
          gpu_uuid="$(printf '%s' "$gpu_uuid" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
          pid="$(printf '%s' "$pid" | tr -d '[:space:]')"
          pname="$(printf '%s' "$pname" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
          used_mem="$(printf '%s' "$used_mem" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
          [ -n "$pid" ] || continue
          [ -r "/proc/$pid/status" ] || continue
          uid_line="$(grep '^Uid:' "/proc/$pid/status" 2>/dev/null || true)"
          [ -n "$uid_line" ] || continue
          set -- $uid_line
          real_uid="$2"
          [ -n "$real_uid" ] || continue
          printf '%s,%s,%s,%s,%s\\n' "$gpu_uuid" "$pid" "$real_uid" "$pname" "$used_mem"
        done
        """
        guard hostMetrics.cpu || hostMetrics.memory || (hostMetrics.network && includesNetworkUsage) else { return command }
        let hostScript = resolveHostCommand(hostCommand, legacyMemoryCommand: memoryCommand)
        command += """

        printf '\\n\(hostSectionSeparator)\\n'
        (
          export NVBEACON_COLLECT_CPU=\(hostMetrics.cpu ? 1 : 0)
          export NVBEACON_COLLECT_MEMORY=\(hostMetrics.memory ? 1 : 0)
          export NVBEACON_COLLECT_NETWORK=\(hostMetrics.network && includesNetworkUsage ? 1 : 0)
          /bin/sh -c \(shellQuote(hostScript))
        ) 2>/dev/null || true
        """
        return command
    }
}
