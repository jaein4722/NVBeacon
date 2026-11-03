import Foundation

public enum RemoteMetricCommands {
    public static let defaultGPUCommand = "nvidia-smi --query-gpu=index,name,uuid,utilization.gpu,memory.used,memory.total,temperature.gpu --format=csv,noheader,nounits"
    public static let legacyGPUCommand = "nvidia-smi --query-gpu=index,name,utilization.gpu,memory.used,memory.total,temperature.gpu --format=csv,noheader,nounits"
    public static let defaultMemoryCommand = "cat /proc/meminfo"
    public static let processDetailsCommand = "nvidia-smi --query-compute-apps=gpu_uuid,pid,process_name,used_gpu_memory --format=csv,noheader,nounits"
    public static let processSectionSeparator = "__GPUUSAGE_PROCESS_SECTION__"
    public static let psSectionSeparator = "__GPUUSAGE_PS_SECTION__"
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
      sed 's/^[[:space:]]*//' /proc/net/dev 2>/dev/null | awk -F'[[:space:]:]+' 'NR > 2 { if ($1 == "lo") next; if ($1 ~ /^(veth|docker|br-|virbr|vnet|tap|tun|wg|zt|tailscale|kube|cni|flannel|cali|dummy|ifb)/) next; if ($10 == "") next; print $1, $2, $10 }'
    fi
    """

    public static func summary(summaryCommand: String, memoryCommand: String = defaultMemoryCommand, includesNetworkUsage: Bool = true) -> String {
        let command = """
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
        printf '\\n\(cpuSectionSeparator)\\n'
        (head -n 1 /proc/stat; sleep 0.2; head -n 1 /proc/stat) 2>/dev/null || true
        printf '\\n\(memorySectionSeparator)\\n'
        (
          \(memoryCommand)
        ) 2>/dev/null || true
        """
        guard includesNetworkUsage else { return command }
        return """
        \(command)
        printf '\\n\(networkSectionSeparator)\\n'
        \(networkSampleCommand)
        """
    }
}
