package dev.nookwifi.helper;

import org.json.JSONException;
import org.json.JSONObject;

/**
 * Builders for reply objects. Unknown values are omitted rather than sent as
 * JSON null, because KOReader's JSON decoders disagree on how null decodes.
 */
final class Replies {
    private Replies() {
    }

    static JSONObject ok() {
        return put(new JSONObject(), "ok", true);
    }

    static JSONObject error(String code) {
        return put(put(new JSONObject(), "ok", false), "error", code);
    }

    // JSONObject.put only throws for non-finite numbers and null keys, neither of which we use.
    static JSONObject put(JSONObject obj, String key, Object value) {
        try {
            return obj.put(key, value);
        } catch (JSONException e) {
            throw new IllegalStateException(e);
        }
    }
}
