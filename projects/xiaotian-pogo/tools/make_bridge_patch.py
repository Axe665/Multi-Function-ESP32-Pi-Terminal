"""Generate a reviewable patch against the local 20261030 bridge snapshot.

Never modifies or flashes the original bridge project.
"""
from pathlib import Path
import difflib
import hashlib
import json

root = Path(__file__).resolve().parents[1]
workspace = root.parents[2]
source = workspace / 'esp/S3_PiBridge_LinkIt_Host_20261030/S3_PiBridge_LinkIt_Host/main/main.c'
original = source.read_text(encoding='utf-8')
text = original

def replace(old, new):
    global text
    if text.count(old) != 1:
        raise RuntimeError('Bridge source changed; review required: ' + old[:60])
    text = text.replace(old, new, 1)

replace('static char s_module_package_transport[24];', '''static char s_module_package_transport[24];
/* Infrared baseline: explicit profile, never infer a product ID from GENERIC. */
static bool s_xiaotian_profile;
static char s_xiaotian_instance[65];
static bool valid_xiaotian_instance(const char *s) {
    if (!s || strlen(s) != 21 || strncmp(s, "xiaotian-", 9)) return false;
    for (unsigned i=9; i<21; ++i)
        if (!((s[i]>='0' && s[i]<='9') || (s[i]>='a' && s[i]<='f'))) return false;
    return true;
}''')
replace('''    if (attached) {
        if (!s_module_config_valid) return false;''', '''    if (attached) {
        if (!s_module_config_valid) return false;
        if (s_xiaotian_profile) {
            json_len = snprintf(json, sizeof(json),
                "{\\"event\\":\\"attach\\",\\"module_id\\":81,\\"module_instance\\":\\"%s\\","
                "\\"module_config\\":{\\"schema\\":\\"module-transport-v1\\","
                "\\"transport_mode\\":\\"fixed_hotspot_lan\\",\\"package_transport\\":\\"data\\","
                "\\"business_adapter\\":\\"xiaotian_https_v2\\",\\"https_port\\":8443,\\"package_available\\":false}}",
                s_xiaotian_instance);
            return json_len>0 && (size_t)json_len<sizeof(json) && pbr_send_frame(1,json);
        }''')
replace('''            module_id, PBRIDGE_INSTANCE);
    }
    if (json_len''', '''            module_id, s_xiaotian_profile ? s_xiaotian_instance : PBRIDGE_INSTANCE);
    }
    if (json_len''')
replace('''                if (combo_valid) {
                    strlcpy(s_module_transport_mode''', '''                const cJSON *adapter = cJSON_GetObjectItemCaseSensitive(config, "business_adapter");
                const cJSON *instance = cJSON_GetObjectItemCaseSensitive(config, "module_instance");
                const cJSON *https_port = cJSON_GetObjectItemCaseSensitive(config, "https_port");
                const bool infrared = cJSON_IsString(adapter) && !strcmp(adapter->valuestring, "xiaotian_https_v2");
                const bool infrared_valid = infrared && rx.frame.module_id==0x51 &&
                    cJSON_IsString(instance) && valid_xiaotian_instance(instance->valuestring) &&
                    cJSON_IsNumber(https_port) && https_port->valuedouble==8443 && combo_valid &&
                    !strcmp(mode->valuestring,"fixed_hotspot_lan");
                if (combo_valid && (!adapter || infrared_valid)) {
                    s_xiaotian_profile=infrared_valid;
                    if(infrared_valid) strlcpy(s_xiaotian_instance,instance->valuestring,sizeof(s_xiaotian_instance));
                    strlcpy(s_module_transport_mode''')
replace('''            pbr_module_id = PBRIDGE_MODULE_ID;
            if (pbr_send_link_event''', '''            pbr_module_id = s_xiaotian_profile ? 0x51 : PBRIDGE_MODULE_ID;
            if (pbr_send_link_event''')
dest = root / 'bridge-adapter'
dest.mkdir(exist_ok=True)
(dest / 'main.c.candidate').write_text(text, encoding='utf-8')
patch = ''.join(difflib.unified_diff(original.splitlines(True), text.splitlines(True),
                                   fromfile='a/main/main.c', tofile='b/main/main.c'))
(dest / 'xiaotian-profile.patch').write_text(patch, encoding='utf-8')
(dest / 'SOURCE.json').write_text(json.dumps(dict(source=str(source),
    source_sha256=hashlib.sha256(source.read_bytes()).hexdigest(),
    normalized_source_sha256=hashlib.sha256(original.encode()).hexdigest(),
    candidate_sha256=hashlib.sha256(text.encode()).hexdigest(),
    changes='Infrared profile recognition only; battery/RFID/secure service untouched',
    flashed=False), ensure_ascii=False, indent=2), encoding='utf-8')
print('Bridge profile patch generated; original unchanged. Review/build before flashing.')
