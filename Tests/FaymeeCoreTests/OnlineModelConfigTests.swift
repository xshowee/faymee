import Foundation
import Testing
@testable import FaymeeCore

@Suite struct CredentialStoreTests {
    @Test func 未写入时返回空字符串_写入可覆盖_写入空字符串会清除() throws {
        let store = InMemoryCredentialStore()

        for slot in CredentialSlot.allCases {
            #expect(store.string(for: slot) == "")
        }

        try store.setString("sk-dash-1", for: .dashScope)
        #expect(store.string(for: .dashScope) == "sk-dash-1")
        #expect(store.string(for: .openAI) == "")

        try store.setString("sk-dash-2", for: .dashScope)
        #expect(store.string(for: .dashScope) == "sk-dash-2")

        try store.setString("", for: .dashScope)
        #expect(store.string(for: .dashScope) == "")
    }
}

@Suite struct OnlineProviderMetadataTests {
    @Test func 转写服务商预设元数据与槽位正确() {
        #expect(OnlineTranscriptionProvider.dashScope.providerID == "dashscope")
        #expect(OnlineTranscriptionProvider.dashScope.defaultModel == "qwen3-asr-flash-filetrans")
        #expect(OnlineTranscriptionProvider.dashScope.suggestedModels == [
            "qwen3-asr-flash-filetrans", "fun-asr", "paraformer-v2",
        ])
        #expect(OnlineTranscriptionProvider.dashScope.credentialSlot == .dashScope)
        #expect(OnlineTranscriptionProvider.dashScope.requiresHTTPS)
        #expect(OnlineTranscriptionProvider.dashScope.requiresAPIKey)

        #expect(OnlineTranscriptionProvider.openAI.providerID == "openai")
        #expect(OnlineTranscriptionProvider.openAI.defaultModel == "gpt-transcribe")
        #expect(OnlineTranscriptionProvider.openAI.credentialSlot == .openAI)

        #expect(OnlineTranscriptionProvider.groq.providerID == "groq")
        #expect(OnlineTranscriptionProvider.groq.defaultModel == "whisper-large-v3-turbo")
        #expect(OnlineTranscriptionProvider.groq.credentialSlot == .groq)

        #expect(OnlineTranscriptionProvider.custom.providerID == "openai-compatible")
        #expect(OnlineTranscriptionProvider.custom.defaultBaseURL == "")
        #expect(OnlineTranscriptionProvider.custom.defaultModel == "")
        #expect(OnlineTranscriptionProvider.custom.suggestedModels.isEmpty)
        #expect(OnlineTranscriptionProvider.custom.credentialSlot == .customTranscription)
        #expect(!OnlineTranscriptionProvider.custom.requiresHTTPS)
        #expect(!OnlineTranscriptionProvider.custom.requiresAPIKey)
    }

    @Test func 纪要服务商预设协议与共享槽位正确() {
        #expect(OnlineMinutesProvider.deepSeek.protocolKind == .openAICompatible)
        #expect(OnlineMinutesProvider.dashScope.protocolKind == .openAICompatible)
        #expect(OnlineMinutesProvider.openAI.protocolKind == .openAICompatible)
        #expect(OnlineMinutesProvider.anthropic.protocolKind == .anthropic)
        #expect(OnlineMinutesProvider.gemini.protocolKind == .gemini)
        #expect(OnlineMinutesProvider.custom.protocolKind == .openAICompatible)

        // 阿里云百炼和 OpenAI 在转写和纪要两侧共用同一钥匙串槽位
        #expect(OnlineMinutesProvider.dashScope.credentialSlot == OnlineTranscriptionProvider.dashScope.credentialSlot)
        #expect(OnlineMinutesProvider.openAI.credentialSlot == OnlineTranscriptionProvider.openAI.credentialSlot)
        // 自定义两侧槽位隔离且允许免密与 http
        #expect(OnlineMinutesProvider.custom.credentialSlot != OnlineTranscriptionProvider.custom.credentialSlot)
        #expect(!OnlineMinutesProvider.custom.requiresHTTPS)
        #expect(!OnlineMinutesProvider.custom.requiresAPIKey)
    }
}

@Suite struct OnlineEndpointConfigTests {
    @Test func 内置预设强制HTTPS并校验模型与密钥() {
        let httpConfig = OnlineEndpointConfig(
            baseURL: "http://api.openai.com/v1",
            model: "gpt-transcribe",
            apiKey: "sk-test",
            requiresHTTPS: true,
            requiresAPIKey: true,
            providerID: "openai"
        )
        #expect(httpConfig.urlValidationError != nil)
        #expect(httpConfig.plaintextHTTPWarning == nil)
        #expect(!httpConfig.isReady)
        #expect(throws: OnlineAPIError.invalidConfiguration(httpConfig.urlValidationError!)) {
            try httpConfig.validateReady()
        }

        let missingKey = OnlineEndpointConfig(
            baseURL: "https://api.openai.com/v1",
            model: "gpt-transcribe",
            apiKey: "   ",
            requiresHTTPS: true,
            requiresAPIKey: true,
            providerID: "openai"
        )
        #expect(missingKey.urlValidationError == nil)
        #expect(!missingKey.isReady)

        let missingModel = OnlineEndpointConfig(
            baseURL: "https://api.openai.com/v1",
            model: "",
            apiKey: "sk-test",
            requiresHTTPS: true,
            requiresAPIKey: true,
            providerID: "openai"
        )
        #expect(!missingModel.isReady)

        let ready = OnlineEndpointConfig(
            baseURL: " https://api.openai.com/v1 ",
            model: " gpt-transcribe ",
            apiKey: " sk-test ",
            requiresHTTPS: true,
            requiresAPIKey: true,
            providerID: "openai"
        )
        #expect(ready.urlValidationError == nil)
        #expect(ready.isReady)
        #expect(ready.sourceIdentifier == "openai/gpt-transcribe")
    }

    @Test func 无效URL被拦截() {
        for bad in ["", "   ", "api.openai.com/v1", "ftp://example.com/v1", "https://", "http:///v1", "https://bad host/v1"] {
            let config = OnlineEndpointConfig(
                baseURL: bad,
                model: "whisper-1",
                apiKey: "",
                requiresHTTPS: false,
                requiresAPIKey: false,
                providerID: "openai-compatible"
            )
            #expect(config.urlValidationError != nil, "expected error for \(bad)")
            #expect(!config.isReady)
        }
    }

    @Test func 自定义允许HTTP且仅对非本机回环返回明文风险提示() {
        for loopback in [
            "http://localhost:8000/v1",
            "http://LOCALHOST:8000/v1",
            "http://127.0.0.1:8000/v1",
            "http://[::1]:8000/v1",
            "https://192.168.1.20:8443/v1",
        ] {
            let config = OnlineEndpointConfig(
                baseURL: loopback,
                model: "whisper-large-v3",
                apiKey: "",
                requiresHTTPS: false,
                requiresAPIKey: false,
                providerID: "openai-compatible"
            )
            #expect(config.urlValidationError == nil, "unexpected error for \(loopback)")
            #expect(config.plaintextHTTPWarning == nil, "unexpected warning for \(loopback)")
            #expect(config.isReady)
        }

        for remotePlaintext in [
            "http://192.168.1.20:8000/v1",
            "http://whisper-node.tailnet.ts.net:8000/v1",
        ] {
            let config = OnlineEndpointConfig(
                baseURL: remotePlaintext,
                model: "whisper-large-v3",
                apiKey: "",
                requiresHTTPS: false,
                requiresAPIKey: false,
                providerID: "openai-compatible"
            )
            #expect(config.urlValidationError == nil)
            #expect(config.plaintextHTTPWarning != nil, "expected plaintext warning for \(remotePlaintext)")
            #expect(config.isReady)
            #expect(config.sourceIdentifier == "openai-compatible/whisper-large-v3")
        }
    }
}

@MainActor
@Suite struct OnlineModelSettingsTests {
    private func withIsolatedDefaults(_ body: (UserDefaults, InMemoryCredentialStore) throws -> Void) rethrows {
        let suiteName = "com.faymee.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let credentials = InMemoryCredentialStore()
        try body(defaults, credentials)
    }

    @Test func 默认保持本机模式_转写与纪要各自独立持久化() {
        withIsolatedDefaults { defaults, credentials in
            let settings = OnlineModelSettings(defaults: defaults, credentials: credentials)
            #expect(settings.transcriptionMode == .local)
            #expect(settings.minutesMode == .local)
            #expect(settings.transcriptionProvider == .dashScope)
            #expect(settings.minutesProvider == .deepSeek)

            settings.transcriptionMode = .online
            settings.transcriptionProvider = .openAI
            #expect(settings.minutesMode == .local)

            let reloaded = OnlineModelSettings(defaults: defaults, credentials: credentials)
            #expect(reloaded.transcriptionMode == .online)
            #expect(reloaded.minutesMode == .local)
            #expect(reloaded.transcriptionProvider == .openAI)
            #expect(reloaded.minutesProvider == .deepSeek)

            reloaded.minutesMode = .online
            reloaded.minutesProvider = .anthropic
            let reloadedAgain = OnlineModelSettings(defaults: defaults, credentials: credentials)
            #expect(reloadedAgain.transcriptionMode == .online)
            #expect(reloadedAgain.minutesMode == .online)
            #expect(reloadedAgain.minutesProvider == .anthropic)
        }
    }

    @Test func 各服务商预设来回切换互不覆盖地址与模型() {
        withIsolatedDefaults { defaults, credentials in
            let settings = OnlineModelSettings(defaults: defaults, credentials: credentials)

            settings.transcriptionProvider = .dashScope
            settings.transcriptionBaseURL = "https://dashscope-intl.aliyuncs.com/api/v1"
            settings.transcriptionModel = "fun-asr"

            settings.transcriptionProvider = .openAI
            #expect(settings.transcriptionBaseURL == OnlineTranscriptionProvider.openAI.defaultBaseURL)
            #expect(settings.transcriptionModel == OnlineTranscriptionProvider.openAI.defaultModel)
            settings.transcriptionBaseURL = "https://proxy.example.com/v1"
            settings.transcriptionModel = "gpt-4o-transcribe"

            settings.transcriptionProvider = .custom
            settings.transcriptionBaseURL = "http://192.168.1.10:8000/v1"
            settings.transcriptionModel = "large-v3"

            // 切回百炼和 OpenAI，各自填写保留且可重新加载
            settings.transcriptionProvider = .dashScope
            #expect(settings.transcriptionBaseURL == "https://dashscope-intl.aliyuncs.com/api/v1")
            #expect(settings.transcriptionModel == "fun-asr")

            settings.transcriptionProvider = .openAI
            #expect(settings.transcriptionBaseURL == "https://proxy.example.com/v1")
            #expect(settings.transcriptionModel == "gpt-4o-transcribe")

            // 纪要侧预设同理独立记住且可清空
            settings.minutesProvider = .deepSeek
            settings.minutesModel = "deepseek-reasoner"
            settings.minutesProvider = .gemini
            settings.minutesModel = ""
            #expect(settings.minutesModel == "")
            settings.minutesProvider = .deepSeek
            #expect(settings.minutesModel == "deepseek-reasoner")

            let reloaded = OnlineModelSettings(defaults: defaults, credentials: credentials)
            reloaded.minutesProvider = .gemini
            #expect(reloaded.minutesModel == "")
            reloaded.transcriptionProvider = .custom
            #expect(reloaded.transcriptionBaseURL == "http://192.168.1.10:8000/v1")
            #expect(reloaded.transcriptionModel == "large-v3")
        }
    }

    @Test func 阿里云百炼与OpenAI密钥跨侧共用_自定义密钥各自独立且可为空() {
        withIsolatedDefaults { defaults, credentials in
            let settings = OnlineModelSettings(defaults: defaults, credentials: credentials)

            // 百炼在转写侧写入，纪要侧自动共用
            settings.transcriptionProvider = .dashScope
            settings.transcriptionAPIKey = "sk-dash-shared"
            settings.minutesProvider = .dashScope
            #expect(settings.minutesAPIKey == "sk-dash-shared")
            #expect(settings.activeMinutesConfig.isReady)

            // 在纪要侧修改 OpenAI 密钥，转写侧同步生效
            settings.minutesProvider = .openAI
            settings.minutesAPIKey = "sk-openai-shared"
            settings.transcriptionProvider = .openAI
            #expect(settings.transcriptionAPIKey == "sk-openai-shared")

            // 自定义转写与自定义纪要各自独立，且允许留空就绪
            settings.transcriptionProvider = .custom
            settings.transcriptionBaseURL = "http://localhost:8000/v1"
            settings.transcriptionModel = "whisper-local"
            settings.transcriptionAPIKey = "transcribe-only-key"

            settings.minutesProvider = .custom
            settings.minutesBaseURL = "http://localhost:11434/v1"
            settings.minutesModel = "qwen2.5:14b"
            #expect(settings.minutesAPIKey == "")
            #expect(settings.activeMinutesConfig.isReady)
            #expect(settings.activeTranscriptionConfig.apiKey == "transcribe-only-key")
        }
    }

    @Test func 配置变化时触发onChange回调_未变化时不重复触发() {
        withIsolatedDefaults { defaults, credentials in
            let settings = OnlineModelSettings(defaults: defaults, credentials: credentials)
            var changeCount = 0
            settings.onChange = { changeCount += 1 }

            // 赋相同默认值不触发
            settings.transcriptionMode = .local
            settings.transcriptionBaseURL = OnlineTranscriptionProvider.dashScope.defaultBaseURL
            #expect(changeCount == 0)

            settings.transcriptionMode = .online
            settings.transcriptionProvider = .openAI
            settings.transcriptionBaseURL = "https://custom-openai.example.com/v1"
            settings.transcriptionModel = "whisper-1"
            settings.transcriptionAPIKey = "sk-123"
            settings.minutesMode = .online
            settings.minutesProvider = .anthropic
            settings.minutesBaseURL = "https://custom-anthropic.example.com/v1"
            settings.minutesModel = "claude-haiku-4-5"
            settings.minutesAPIKey = "sk-ant-123"
            #expect(changeCount == 10)
        }
    }
}
