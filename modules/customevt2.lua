local m = {}

local function log_registers(registers)
    log("---------------------------------------")
    local keys = {}
    for k,_ in pairs(registers) do
        keys[#keys + 1] = k
    end
    table.sort(keys)
    for _,k in ipairs(keys) do
        local v = registers[k]
        if k:sub(1,1) == "r" then
            v = memory.unpack("u64", v)
            log(string.format("register: %s = %s (HEX), %s (DEC)", k, memory.hex(v), v))
        else
            log(string.format("register: %s = %s (HEX str)", k, memory.hex(v)))
        end
    end
    log("---------------------------------------")
end

function m.finish_quickly(ctx, event_id, registers)
    log(string.format("custom:check_end_of_half: (event_id:%s, registers:%s)", event_id, registers))
    log_registers(registers)

    -- set end-of-half flag
    return {
        rax = "\x01" .. registers.rax:sub(2,8)  -- set al = 1
    }
end

function m.init(ctx)
    -- find the place where want to hook
    --[[
    0000000140A6C54A | 45:84C0                         | test r8b,r8b                            |
    0000000140A6C54D | 75 13                           | jne pes2021.140A6C562                   |
    0000000140A6C54F | F3:0F1005 B147BE01              | movss xmm0,dword ptr ds:[142650D08]     |
    0000000140A6C557 | F3:0F58C2                       | addss xmm0,xmm2                         |
    0000000140A6C55B | 0F2FD8                          | comiss xmm3,xmm0                        |
    0000000140A6C55E | 0F93C0                          | setae al                                |
    0000000140A6C561 | C3                              | ret                                     |
    0000000140A6C562 | F3:0F1005 9A47BE01              | movss xmm0,dword ptr ds:[142650D04]     |
    0000000140A6C56A | F3:0F58C2                       | addss xmm0,xmm2                         |
    0000000140A6C56E | 0F2FD8                          | comiss xmm3,xmm0                        |
    0000000140A6C571 | 0F93C0                          | setae al                                |
    0000000140A6C574 | C3                              | ret                                     |
    --]]
    local addr = memory.search_process("\xf3\x0f\x58\xc2\x0f\x2f\xd8\x0f\x93\xc0\xc3\xf3\x0f\x10\x05")
    if addr == nil then
        error("code location not found")
    end
    addr = addr - 0x57 + 0x4a
    log("code location: " .. memory.hex(addr))

    -- check if custom event trigger is supported
    if not ctx.custom_evt_rbx then
        error("custom events are not supported. Upgrade your sider")
    end

    -- get unique id for the custom event name
    local event_id = ctx.get_event_id("custom:check_end_of_half")
    log(string.format("event_id: %d", event_id))

    -- put event trigger into codecave
    local codecave = memory.allocate_codecave(64)
    log("code cave allocated at: " .. memory.hex(codecave))
    memory.write(codecave,
        "\x53" ..                                                -- push rbx
        "\x51" ..                                                -- push rcx
        "\x48\xbb" .. memory.pack("u64", ctx.custom_evt_rbx) ..  -- mov rbx, <sider_custom_event_rbx_hk>
        "\x66\xb9" .. memory.pack("u16", event_id) ..            -- mov cx, <event_id>
        "\xff\xd3" ..                                            -- call rbx
        "\x48\x83\xc4\x10" ..                                    -- add rsp,10h
        "\xc3"                                                   -- ret
    )

    -- connect event trigger with place in the game code
    -- 1. put an indirect jump instruction using that addr that just folllows
    -- 2. put the 8-byte codecave addr right after
    memory.write(addr, "\xff\x25\x00\x00\x00\x00")
    memory.write(addr + 6, memory.pack("u64", codecave))

    -- register for custom events
    ctx.register("custom:check_end_of_half", m.finish_quickly)
end

return m
