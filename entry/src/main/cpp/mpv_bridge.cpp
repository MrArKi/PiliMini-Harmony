// 单libmpv实例拥有音画时基。解码/网络/事件线程不调用ArkTS，退出在异步工作线程完成。
#include <napi/native_api.h>
#include <hilog/log.h>
#include <mpv/client.h>
#include <atomic>
#include <algorithm>
#include <cmath>
#include <memory>
#include <mutex>
#include <stdexcept>
#include <string>
#include <thread>
#include <pthread.h>
#include <unordered_map>
#include <vector>

namespace {
constexpr unsigned DOMAIN = 0x3200;
std::atomic<int> eventThreads{0};
struct Event { std::string type; int code; };

napi_value Text(napi_env env, const std::string &text) {
    napi_value value; napi_create_string_utf8(env, text.c_str(), text.size(), &value); return value;
}
napi_value Number(napi_env env, double number) {
    napi_value value; napi_create_double(env, number, &value); return value;
}
void Bool(napi_env env, napi_value object, const char *key, bool flag) {
    napi_value value; napi_get_boolean(env, flag, &value); napi_set_named_property(env, object, key, value);
}
std::string String(napi_env env, napi_value value) {
    size_t size = 0;
    if (napi_get_value_string_utf8(env, value, nullptr, 0, &size) != napi_ok || size > 65536)
        throw std::runtime_error("Invalid player string");
    std::vector<char> buffer(size + 1);
    if (napi_get_value_string_utf8(env, value, buffer.data(), buffer.size(), &size) != napi_ok)
        throw std::runtime_error("Invalid player string");
    if (std::find(buffer.begin(), buffer.begin() + size, '\0') != buffer.begin() + size)
        throw std::runtime_error("Invalid embedded null");
    return std::string(buffer.data(), size);
}
double Double(napi_env env, napi_value value) {
    double number = 0;
    if (napi_get_value_double(env, value, &number) != napi_ok || !std::isfinite(number))
        throw std::runtime_error("Invalid player number");
    return number;
}
bool Flag(napi_env env, napi_value value) {
    bool flag = false;
    if (napi_get_value_bool(env, value, &flag) != napi_ok) throw std::runtime_error("Invalid player boolean");
    return flag;
}
uint32_t Handle(napi_env env, napi_value value) {
    const double id = Double(env, value);
    if (id < 1 || id > UINT32_MAX || std::floor(id) != id) throw std::runtime_error("Invalid player handle");
    return static_cast<uint32_t>(id);
}
napi_value Undefined(napi_env env) { napi_value value; napi_get_undefined(env, &value); return value; }
void Check(int result) { if (result < 0) throw std::runtime_error(mpv_error_string(result)); }

void Deliver(napi_env env, napi_value callback, void *, void *data) {
    std::unique_ptr<Event> event(static_cast<Event *>(data));
    if (!env || !callback) return; // TSFN abort也会把尚未投递的数据交还清理。
    napi_value value; napi_create_object(env, &value);
    napi_set_named_property(env, value, "type", Text(env, event->type));
    napi_set_named_property(env, value, "code", Number(env, event->code));
    napi_value result, receiver = Undefined(env);
    napi_call_function(env, receiver, callback, 1, &value, &result);
}

class Engine {
public:
    mpv_handle *mpv = nullptr;
    napi_env owner = nullptr;
    napi_threadsafe_function callback = nullptr;
    std::atomic<bool> closing{false};
    std::thread events;

    ~Engine() { Close(); }
    void Option(const char *key, const std::string &value) {
        int result = mpv_set_option_string(mpv, key, value.c_str());
        if (result < 0) throw std::runtime_error(std::string(key) + ": " + mpv_error_string(result));
    }
    void Emit(const char *type, int code = 0) {
        if (closing.load()) return;
        auto event = std::make_unique<Event>(Event{type, code});
        if (napi_call_threadsafe_function(callback, event.get(), napi_tsfn_nonblocking) == napi_ok) event.release();
    }
    void Start() {
        events = std::thread([this]() {
            pthread_setname_np(pthread_self(), "pm-mpv-events");
            eventThreads++;
            while (!closing.load()) {
                // 阻塞等待事件；Close使用mpv_wakeup解除等待，暂停时不轮询唤醒。
                mpv_event *event = mpv_wait_event(mpv, -1);
                if (closing.load()) break;
                switch (event->event_id) {
                case MPV_EVENT_LOG_MESSAGE: {
                    const auto *message = static_cast<mpv_event_log_message *>(event->data);
                    const std::string detail = message->text ? message->text : "";
                    // 只留内核警告/错误；不把播放地址或认证字段写入应用日志。
                    if (detail.find("://") == std::string::npos && detail.find("Cookie") == std::string::npos &&
                        detail.find("cookie") == std::string::npos && detail.find("SESSDATA") == std::string::npos) {
                        OH_LOG_Print(LOG_APP, LOG_WARN, DOMAIN, "PiliMini-mpv", "%{public}s: %{public}s", message->prefix, detail.c_str());
                    }
                    if (std::string(message->prefix) == "cplayer" &&
                        detail.find("Error opening/initializing the selected video_out") != std::string::npos)
                        Emit("video-output-error");
                    break;
                }
                case MPV_EVENT_FILE_LOADED: Emit("loaded"); break;
                case MPV_EVENT_PLAYBACK_RESTART: Emit("restart"); break;
                case MPV_EVENT_VIDEO_RECONFIG:
                    OH_LOG_Print(LOG_APP, LOG_INFO, DOMAIN, "PiliMini-mpv",
                        "video output=%{public}s decoder=%{public}s size=%{public}.0fx%{public}.0f",
                        TextValue("current-gpu-context").c_str(), TextValue("hwdec-current").c_str(),
                        Value("video-out-params/w"), Value("video-out-params/h"));
                    Emit("video"); break;
                case MPV_EVENT_SEEK: Emit("seek"); break;
                case MPV_EVENT_AUDIO_RECONFIG: Emit("audio"); break;
                case MPV_EVENT_PROPERTY_CHANGE: Emit("state"); break;
                case MPV_EVENT_COMMAND_REPLY:
                    if (event->error < 0) Emit("command-error", event->error);
                    break;
                case MPV_EVENT_END_FILE: {
                    auto *end = static_cast<mpv_event_end_file *>(event->data);
                    if (end->reason == MPV_END_FILE_REASON_ERROR) Emit("error", end->error);
                    else if (end->reason == MPV_END_FILE_REASON_EOF) Emit("ended");
                    break;
                }
                default: break;
                }
            }
            eventThreads--;
            if (callback) { napi_release_threadsafe_function(callback, napi_tsfn_abort); callback = nullptr; }
        });
    }
    void Close() {
        if (closing.exchange(true)) return;
        if (mpv) mpv_wakeup(mpv);
        if (events.joinable()) events.join();
        else if (callback) { napi_release_threadsafe_function(callback, napi_tsfn_abort); callback = nullptr; }
        if (mpv) { mpv_terminate_destroy(mpv); mpv = nullptr; }
    }
    void Command(const std::vector<std::string> &args) {
        std::vector<const char *> values;
        for (const auto &arg : args) values.push_back(arg.c_str());
        values.push_back(nullptr);
        Check(mpv_command_async(mpv, 0, values.data()));
    }
    double Value(const char *key) {
        double value = 0; mpv_get_property(mpv, key, MPV_FORMAT_DOUBLE, &value);
        return std::isfinite(value) ? value : 0;
    }
    bool FlagValue(const char *key) { int value = 0; mpv_get_property(mpv, key, MPV_FORMAT_FLAG, &value); return value != 0; }
    double CacheBytes() {
        mpv_node node{};
        double bytes = 0;
        if (mpv_get_property(mpv, "demuxer-cache-state", MPV_FORMAT_NODE, &node) >= 0) {
            if (node.format == MPV_FORMAT_NODE_MAP) {
                for (int i = 0; i < node.u.list->num; ++i) {
                    const auto &value = node.u.list->values[i];
                    if (std::string(node.u.list->keys[i]) == "total-bytes" && value.format == MPV_FORMAT_INT64)
                        bytes = static_cast<double>(value.u.int64);
                }
            }
            mpv_free_node_contents(&node);
        }
        return bytes;
    }
    std::string TextValue(const char *key) {
        char *value = mpv_get_property_string(mpv, key);
        std::string result = value ? value : ""; mpv_free(value); return result;
    }
};

std::mutex registryMutex;
std::unordered_map<uint32_t, std::shared_ptr<Engine>> registry;
std::atomic<uint32_t> nextHandle{1};
std::shared_ptr<Engine> Get(napi_env env, napi_value value) {
    const auto id = Handle(env, value);
    std::lock_guard<std::mutex> lock(registryMutex);
    auto found = registry.find(id);
    if (found == registry.end() || found->second->owner != env || found->second->closing.load())
        throw std::runtime_error("Player released");
    return found->second;
}

napi_value Create(napi_env env, napi_callback_info info) {
    try {
        size_t argc = 3; napi_value args[3]; napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
        if (argc != 3) throw std::runtime_error("Invalid create arguments");
        napi_valuetype listenerType;
        if (napi_typeof(env, args[2], &listenerType) != napi_ok || listenerType != napi_function)
            throw std::runtime_error("Invalid player callback");
        auto engine = std::make_shared<Engine>();
        engine->owner = env;
        engine->mpv = mpv_create();
        if (!engine->mpv) throw std::runtime_error("Cannot create libmpv");
        Check(mpv_request_log_messages(engine->mpv, "warn"));
        engine->Option("config", "no");
        engine->Option("terminal", "no");
        engine->Option("input-default-bindings", "no");
        engine->Option("input-vo-keyboard", "no");
        // CDN地址已由业务层解析，控制层由ArkUI负责，无需mpv内置Lua界面/解析器。
        // Nara发布库默认会为这些脚本各启动线程；裁剪Lua的模拟器库没有相应选项。
        const char *scripts[] = {"osc", "ytdl", "load-stats-overlay", "load-console",
            "load-auto-profiles", "load-select", "load-positioning", "load-commands",
            "load-context-menu", "load-scripts"};
        for (const char *option : scripts) {
            const int result = mpv_set_option_string(engine->mpv, option, "no");
            if (result != MPV_ERROR_OPTION_NOT_FOUND) Check(result);
        }
        engine->Option("idle", "yes");
        engine->Option("keep-open", "always");
        engine->Option("pause", "yes");
        engine->Option("video-sync", "display-resample");
        engine->Option("cache", "yes");
        engine->Option("demuxer-max-bytes", "4MiB");
        engine->Option("demuxer-max-back-bytes", "4MiB");
        engine->Option("cache-secs", "16");
        engine->Option("demuxer-hysteresis-secs", "10.667");
        engine->Option("network-timeout", "10");
        engine->Option("vo", "gpu-next");
        // 与Nara OHOS接入一致，允许发布库自动选择GPU后端。
        // XComponent使用RGBA8888，避免EGL默认RGB配置在真机创建窗口失败；
        // RGBA8同时保留OpenGL/OHCodec硬解通路，不能只靠Vulkan软解掩盖黑屏。
        engine->Option("egl-output-format", "rgba8");
        engine->Option("ao", "ohaudio");
        const bool hardware = Flag(env, args[1]);
        engine->Option("hwdec", hardware ? "auto" : "no");
        engine->Option("wid", String(env, args[0]));
        Check(mpv_initialize(engine->mpv));
        const char *properties[] = {"pause", "paused-for-cache", "seeking", "eof-reached", "video-params"};
        for (const char *property : properties) Check(mpv_observe_property(engine->mpv, 0, property, MPV_FORMAT_NONE));
        napi_value label = Text(env, "PiliMini libmpv events");
        if (napi_create_threadsafe_function(env, args[2], nullptr, label, 128, 1,
            nullptr, nullptr, nullptr, Deliver, &engine->callback) != napi_ok) throw std::runtime_error("Cannot create player callback");
        const uint32_t id = nextHandle++;
        engine->Start();
        { std::lock_guard<std::mutex> lock(registryMutex); registry.emplace(id, engine); }
        OH_LOG_Print(LOG_APP, LOG_INFO, DOMAIN, "PiliMini-mpv", "created handle=%{public}u hardware=%{public}d", id, hardware);
        return Number(env, id);
    } catch (const std::exception &error) { napi_throw_error(env, nullptr, error.what()); return nullptr; }
}

napi_value Load(napi_env env, napi_callback_info info) {
    try {
        size_t argc = 6; napi_value args[6]; napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
        if (argc != 6) throw std::runtime_error("Invalid load arguments");
        auto engine = Get(env, args[0]);
        const std::string video = String(env, args[1]), audio = String(env, args[2]), ua = String(env, args[3]);
        Check(mpv_set_property_string(engine->mpv, "user-agent", ua.c_str()));
        Check(mpv_set_property_string(engine->mpv, "referrer", "https://www.bilibili.com/"));
        // 节点数组传入外置音轨，无冒号/逗号/反斜线字符串转义；混流/本地清空旧轨。
        mpv_node audioNode{}; mpv_node_list audioList{}; mpv_node audioValue{};
        audioValue.format = MPV_FORMAT_STRING; audioValue.u.string = const_cast<char *>(audio.c_str());
        audioList.num = audio.empty() ? 0 : 1; audioList.values = &audioValue;
        audioNode.format = MPV_FORMAT_NODE_ARRAY; audioNode.u.list = &audioList;
        Check(mpv_set_property(engine->mpv, "audio-files", MPV_FORMAT_NODE, &audioNode));
        Check(mpv_set_property_string(engine->mpv, "vid", "auto"));
        Check(mpv_set_property_string(engine->mpv, "pause", Flag(env, args[5]) ? "yes" : "no"));
        const std::string start = std::to_string(std::max(0.0, Double(env, args[4])) / 1000.0);
        engine->Command({"loadfile", video, "replace", "-1", "start=" + start});
        return Undefined(env);
    } catch (const std::exception &error) { napi_throw_error(env, nullptr, error.what()); return nullptr; }
}

napi_value Command(napi_env env, napi_callback_info info) {
    try {
        size_t argc = 2; napi_value args[2]; napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
        if (argc != 2) throw std::runtime_error("Invalid command arguments");
        auto engine = Get(env, args[0]);
        bool array = false;
        if (napi_is_array(env, args[1], &array) != napi_ok || !array) throw std::runtime_error("Invalid command array");
        uint32_t size = 0; napi_get_array_length(env, args[1], &size);
        if (size == 0 || size > 16) throw std::runtime_error("Invalid command size");
        std::vector<std::string> values;
        for (uint32_t index = 0; index < size; ++index) {
            napi_value value; napi_get_element(env, args[1], index, &value); values.push_back(String(env, value));
        }
        engine->Command(values);
        return Undefined(env);
    } catch (const std::exception &error) { napi_throw_error(env, nullptr, error.what()); return nullptr; }
}

napi_value Set(napi_env env, napi_callback_info info) {
    try {
        size_t argc = 3; napi_value args[3]; napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
        if (argc != 3) throw std::runtime_error("Invalid set arguments");
        auto engine = Get(env, args[0]);
        Check(mpv_set_property_string(engine->mpv, String(env, args[1]).c_str(), String(env, args[2]).c_str()));
        return Undefined(env);
    } catch (const std::exception &error) { napi_throw_error(env, nullptr, error.what()); return nullptr; }
}

napi_value Snapshot(napi_env env, napi_callback_info info) {
    try {
        size_t argc = 2; napi_value args[2]; napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
        if (argc < 1) throw std::runtime_error("Invalid snapshot arguments");
        auto engine = Get(env, args[0]);
        const bool diagnostics = argc > 1 && Flag(env, args[1]);
        napi_value value; napi_create_object(env, &value);
        napi_set_named_property(env, value, "position", Number(env, engine->Value("time-pos") * 1000));
        napi_set_named_property(env, value, "duration", Number(env, engine->Value("duration") * 1000));
        napi_set_named_property(env, value, "buffered", Number(env, engine->Value("demuxer-cache-time") * 1000));
        napi_set_named_property(env, value, "width", Number(env, engine->Value("video-params/dw")));
        napi_set_named_property(env, value, "height", Number(env, engine->Value("video-params/dh")));
        napi_set_named_property(env, value, "decoder", Text(env, diagnostics ? engine->TextValue("hwdec-current") : ""));
        napi_set_named_property(env, value, "videoCodec", Text(env, diagnostics ? engine->TextValue("video-codec") : ""));
        double avSync = 0;
        const bool syncValid = diagnostics && mpv_get_property(engine->mpv, "avsync", MPV_FORMAT_DOUBLE, &avSync) >= 0 && std::isfinite(avSync);
        napi_set_named_property(env, value, "avSyncMs", Number(env, syncValid ? avSync * 1000 : 0));
        napi_set_named_property(env, value, "cacheBytes", Number(env, diagnostics ? engine->CacheBytes() : 0));
        Bool(env, value, "syncValid", syncValid);
        Bool(env, value, "paused", engine->FlagValue("pause"));
        Bool(env, value, "buffering", engine->FlagValue("paused-for-cache"));
        Bool(env, value, "seeking", engine->FlagValue("seeking"));
        Bool(env, value, "ended", engine->FlagValue("eof-reached"));
        Bool(env, value, "audioReady", engine->Value("audio-params/samplerate") > 0);
        Bool(env, value, "videoEnabled", engine->TextValue("vid") != "no");
        Bool(env, value, "outputReady", engine->FlagValue("vo-configured") &&
            engine->Value("video-out-params/w") > 0 && engine->Value("video-out-params/h") > 0);
        return value;
    } catch (const std::exception &error) { napi_throw_error(env, nullptr, error.what()); return nullptr; }
}

struct Disposal { napi_async_work work; napi_deferred result; std::shared_ptr<Engine> engine; uint32_t id; };
napi_value Dispose(napi_env env, napi_callback_info info) {
  try {
    size_t argc = 1; napi_value arg; napi_get_cb_info(env, info, &argc, &arg, nullptr, nullptr);
    if (argc != 1) throw std::runtime_error("Invalid dispose arguments");
    auto disposal = std::make_unique<Disposal>();
    disposal->id = Handle(env, arg);
    { std::lock_guard<std::mutex> lock(registryMutex);
      auto found = registry.find(disposal->id);
      if (found != registry.end()) {
          if (found->second->owner != env) throw std::runtime_error("Invalid player owner");
          disposal->engine = found->second; registry.erase(found);
      }
    }
    napi_value promise; napi_create_promise(env, &disposal->result, &promise);
    const napi_status created = napi_create_async_work(env, nullptr, Text(env, "release libmpv"),
        [](napi_env, void *data) { auto *job = static_cast<Disposal *>(data); if (job->engine) job->engine->Close(); },
        [](napi_env env, napi_status, void *data) {
            std::unique_ptr<Disposal> job(static_cast<Disposal *>(data));
            OH_LOG_Print(LOG_APP, LOG_INFO, DOMAIN, "PiliMini-mpv", "released handle=%{public}u", job->id);
            napi_resolve_deferred(env, job->result, Undefined(env)); napi_delete_async_work(env, job->work);
        }, disposal.get(), &disposal->work);
    if (created != napi_ok || napi_queue_async_work(env, disposal->work) != napi_ok) {
        if (created == napi_ok) napi_delete_async_work(env, disposal->work);
        // 任务创建失败时也必须释放句柄，不能丢失registry之外的原生对象。
        if (disposal->engine) disposal->engine->Close();
        napi_reject_deferred(env, disposal->result, Text(env, "Cannot queue player disposal"));
    } else disposal.release();
    return promise;
  } catch (const std::exception &error) { napi_throw_error(env, nullptr, error.what()); return nullptr; }
}

napi_value Stats(napi_env env, napi_callback_info) {
    napi_value value; napi_create_object(env, &value);
    { std::lock_guard<std::mutex> lock(registryMutex);
      napi_set_named_property(env, value, "instances", Number(env, registry.size())); }
    napi_set_named_property(env, value, "eventThreads", Number(env, eventThreads.load()));
    return value;
}

napi_value Init(napi_env env, napi_value exports) {
    napi_add_env_cleanup_hook(env, [](void *data) {
        std::vector<std::shared_ptr<Engine>> engines;
        {
            std::lock_guard<std::mutex> lock(registryMutex);
            for (auto it = registry.begin(); it != registry.end();) {
                if (it->second->owner == data) { engines.push_back(it->second); it = registry.erase(it); }
                else ++it;
            }
        }
        for (auto &engine : engines) engine->Close();
    }, env);
    napi_property_descriptor properties[] = {
        {"create", nullptr, Create, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"load", nullptr, Load, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"command", nullptr, Command, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"set", nullptr, Set, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"snapshot", nullptr, Snapshot, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"dispose", nullptr, Dispose, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"stats", nullptr, Stats, nullptr, nullptr, nullptr, napi_default, nullptr}
    };
    napi_define_properties(env, exports, sizeof(properties) / sizeof(properties[0]), properties);
    return exports;
}
} // namespace

static napi_module module = {1, 0, nullptr, Init, "pilimini_player", nullptr, {0}};
extern "C" __attribute__((constructor)) void RegisterPlayer() { napi_module_register(&module); }
