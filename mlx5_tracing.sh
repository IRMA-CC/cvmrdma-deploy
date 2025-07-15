echo function > /sys/kernel/debug/tracing/current_tracer

# 3. Clear previous trace
echo > /sys/kernel/debug/tracing/trace

# 4. Set filter to mlx5e_xmit (you can add others too)
# echo ':mod:mlx5_core' > /sys/kernel/debug/tracing/set_ftrace_filter
echo mlx5e_xmit > /sys/kernel/debug/tracing/set_ftrace_filter

# 5. Enable tracing
echo 1 > /sys/kernel/debug/tracing/tracing_on

# 6. Let it run for a bit while traffic is generated

# 7. Read the trace log
cat /sys/kernel/debug/tracing/trace

# 8. Disable tracing
# echo 0 > /sys/kernel/debug/tracing/tracing_on