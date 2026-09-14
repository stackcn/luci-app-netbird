// SPDX-License-Identifier: Apache-2.0
//
// Remote-safe reconnect helper.
//
// LuCI may itself be reached through the NetBird tunnel. Reconnect therefore
// must not be implemented as two browser-side RPC calls (do_down -> do_up):
// the first call destroys the transport needed to deliver the second one.
// This RPC returns before the tunnel is dropped, then performs the sequence
// locally on the router and reuses the existing luci.netbird do_up method.

import { popen, access } from 'fs';
import * as uci from 'uci';

function ok(data) {
    return { ok: true, data: data || {} };
}

function err(message) {
    return { ok: false, code: 'cli_error', message: message };
}

function keep_desired_connected() {
    let c = uci.cursor();
    if (c.get('netbird', 'runtime') == null)
        c.set('netbird', 'runtime', 'state');
    c.set('netbird', 'runtime', 'desired_connected', '1');
    c.commit('netbird');
}

function schedule_reconnect() {
    // Entire command is a literal: no user-controlled shell input is interpolated.
    // Delay briefly so rpcd/uhttpd can flush the successful RPC response before
    // netbird down removes the route used by a remote LuCI session. do_up is
    // intentionally invoked through ubus so the canonical reconnect logic stays
    // in one place (URL handling, polling, conntrack flush, error classification).
    let cmd = "( sleep 1; /usr/bin/netbird down >/dev/null 2>&1; ubus -t 90 call luci.netbird do_up '{\"management_url\":\"\",\"setup_key\":\"\",\"caller\":\"\"}' >/tmp/luci-netbird-reconnect.log 2>&1 ) >/dev/null 2>&1 &";
    let fd = popen(cmd, 'r');
    if (fd == null)
        return false;
    fd.read('all');
    let rc = fd.close();
    return rc == 0 || rc == null;
}

return {
    'luci.netbird.reconnect': {
        do_reconnect: {
            args: {},
            call: function() {
                if (!access('/usr/bin/netbird', 'x'))
                    return err('The netbird binary is not installed.');

                // This action means "stay connected". Do not route it through
                // do_down, because do_down deliberately records the opposite
                // user intent and disables automatic recovery.
                keep_desired_connected();

                if (!schedule_reconnect())
                    return err('Failed to schedule the NetBird reconnect.');

                return ok({ scheduled: true });
            },
        },
    },
};
