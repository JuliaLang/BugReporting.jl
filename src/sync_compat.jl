
if VERSION < v"1.5.0-DEV.455"
    function sync_end(refs)
        local c_ex
        defined = false
        t = current_task()
        cond = Threads.Condition()
        lock(cond)
        nremaining = length(refs)
        for r in refs
            schedule(Task(()->begin
                try
                    wait(r)
                    lock(cond)
                    nremaining -= 1
                    nremaining == 0 && notify(cond)
                    unlock(cond)
                catch e
                    lock(cond)
                    notify(cond, e; error=true)
                    unlock(cond)
                end
            end))
        end
        wait(cond)
        unlock(cond)
    end

    """
        Experimental.@sync
    Wait until all lexically-enclosed uses of `@async`, `@spawn`, `@spawnat` and `@distributed`
    are complete, or at least one of them has errored. The first exception is immediately
    rethrown. It is the responsibility of the user to cancel any still-running operations
    during error handling.
    !!! Note
        This interface is experimental and subject to change or removal without notice.
    """
    macro correct_sync(block)
        var = esc(sync_varname)
        quote
            let $var = Any[]
                v = $(esc(block))
                sync_end($var)
                v
            end
        end
    end
else
    macro correct_sync(block)
        var = esc(sync_varname)
        quote
            let $var = Any[]
                v = $(esc(block))
                Base.Experimental.sync_end($var)
                v
            end
        end
    end
end
