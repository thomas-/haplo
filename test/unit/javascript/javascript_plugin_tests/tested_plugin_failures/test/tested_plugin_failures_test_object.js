/* Haplo Platform                                    https://haplo.org
 * (c) Haplo Services Ltd 2006 - 2020            https://www.haplo.com
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/.         */


t.test(function() {
    var postLast2 = t.post("/do/tested_plugin_failures/posting2", {}, {body:{h1:"value1", h2:"value2"}, kind:"json"});
    var requestAsSeenByPlugin = tested_plugin_failures.requestAsSeenByPlugin;
    t.assertObject(requestAsSeenByPlugin.body, {h1:"value2", h2:"value1"});
});