/* Haplo Platform                                     http://haplo.org
 * (c) Haplo Services Ltd 2006 - 2016    http://www.haplo-services.com
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/.         */

package org.haplo.jsinterface.remote;

import org.haplo.javascript.Runtime;
import org.haplo.javascript.OAPIException;
import org.haplo.jsinterface.KScriptable;
import org.mozilla.javascript.*;

import org.haplo.jsinterface.remote.app.*;

public class KAuthenticationService extends KScriptable {
    private AppAuthenticationService service;

    public KAuthenticationService() {
    }

    public void setService(AppAuthenticationService service) {
        this.service = service;
    }

    // --------------------------------------------------------------------------------------------------------------
    public void jsConstructor() {
    }

    public String getClassName() {
        return "$AuthenticationService";
    }

    // --------------------------------------------------------------------------------------------------------------
    static public Scriptable fromAppAuthenticationService(AppAuthenticationService appObj) {
        KAuthenticationService service = (KAuthenticationService)Runtime.getCurrentRuntime().createHostObject("$AuthenticationService");
        service.setService(appObj);
        return service;
    }

    // --------------------------------------------------------------------------------------------------------------
    public static Scriptable jsStaticFunction_findService(boolean searchByName, String serviceName) {
        Runtime.privilegeRequired("pRemoteAuthenticationService", "use an authentication service");
        AppAuthenticationService appService = rubyInterface.createServiceObject(searchByName, serviceName);
        if(appService == null) {
            throw new OAPIException("Could not find credentials for authentication service in application keychain.");
        }
        return fromAppAuthenticationService(appService);
    }

    // --------------------------------------------------------------------------------------------------------------
    public void jsFunction__connect() {
        this.service.connect();
    }

    public void jsFunction__disconnect() {
        this.service.disconnect();
    }

    // --------------------------------------------------------------------------------------------------------------
    public String jsGet_name() {
        return this.service.getName();
    }

    public boolean jsGet_connected() {
        return this.service.isConnected();
    }

    public Object jsFunction_authenticate(String username, String password) {
        if(username == null || password == null) {
            throw new OAPIException("Username and password required for authenticate function.");
        }
        return decodingJSONResult(this.service.authenticate(username, password));
    }

    public Object jsFunction_search(String criteria) {
        if(criteria == null) {
            throw new OAPIException("Criteria required for search function.");
        }
        return decodingJSONResult(this.service.search(criteria));
    }

    private Object decodingJSONResult(String json) {
        Object decoded;
        try {
            decoded = Runtime.getCurrentRuntime().makeJsonParser().parseValue(json);
        } catch(org.mozilla.javascript.json.JsonParser.ParseException e) {
            throw new OAPIException("Internal error (decode result)");
        }
        return decoded;
    }

    // --------------------------------------------------------------------------------------------------------------
    // Start of the OAuth stuff, because this is a good a place as any to put it
    public static String jsStaticFunction_urlToStartOAuth(boolean haveData, String data, boolean haveName, String name,
            boolean haveExtraConfiguration, Scriptable extraConfiguration) {
        Runtime.privilegeRequired("pStartOAuth", "start OAuth");
        String json;
        if(haveExtraConfiguration) {
            json  = Runtime.getCurrentRuntime().jsonStringify(extraConfiguration);
        } else {
            json = "{}";
        }
        return rubyInterface.urlToStartOAuth(haveData, data, haveName, name, json);
    }

    // --------------------------------------------------------------------------------------------------------------
    // Interface to Ruby functions
    public interface Ruby {
        public AppAuthenticationService createServiceObject(boolean searchByName, String serviceName);

        public String urlToStartOAuth(boolean haveData, String data, boolean haveName, String name, String extraConfiguration);
    }
    private static Ruby rubyInterface;

    public static void setRubyInterface(Ruby ri) {
        rubyInterface = ri;
    }
}
