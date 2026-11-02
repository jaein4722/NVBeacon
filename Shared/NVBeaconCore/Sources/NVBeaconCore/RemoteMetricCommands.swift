import Foundation

public enum RemoteMetricCommands {
    public static let defaultGPUCommand = "nvidia-smi --query-gpu=index,name,uuid,utilization.gpu,memory.used,memory.total,temperature.gpu --format=csv,noheader,nounits"
    public static let legacyGPUCommand = "nvidia-smi --query-gpu=index,name,utilization.gpu,memory.used,memory.total,temperature.gpu --format=csv,noheader,nounits"
    public static let defaultMemoryCommand = "cat /proc/meminfo"
    public static let processDetailsCommand = "nvidia-smi --query-compute-apps=gpu_uuid,pid,process_name,used_gpu_memory --format=csv,noheader,nounits"
    public static let processSectionSeparator = "__GPUUSAGE_PROCESS_SECTION__"
    public static let psSectionSeparator = "__GPUUSAGE_PS_SECTION__"
    public static let memorySectionSeparator = "__NVBEACON_MEMORY_SECTION__"

    public static func summary(summaryCommand: String, memoryCommand: String = defaultMemoryCommand) -> String {
        """
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
        printf '\\n\(memorySectionSeparator)\\n'
        (
          \(memoryCommand)
        ) 2>/dev/null || true
        """
    }
}
