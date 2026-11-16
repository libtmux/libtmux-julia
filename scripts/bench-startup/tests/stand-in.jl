# Stands in for both `julia` and `tmux` when the driver starts its children. The
# run test sets LTJ_STAND_IN_TOML to the measurement a core process reports.
if "-V" in ARGS
    println("tmux 3.7c")
elseif "-e" in ARGS
    println("LTJ_STARTUP_BASELINE\t1.13.1\t1\t4096")
else
    println("LTJ_STARTUP_PHASE\tpackage_load\tpass\t5\t6\t7")
    println("LTJ_STARTUP_TOML_BEGIN")
    print(ENV["LTJ_STAND_IN_TOML"])
    println("LTJ_STARTUP_TOML_END")
end
