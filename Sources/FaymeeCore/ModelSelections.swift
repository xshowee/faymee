import Foundation
import Observation

/// 设置里每个用途选中的模型 id，存在 UserDefaults（键 `model.<用途>`）。
///
/// - 某个用途没存过时决定默认值（`ModelCatalog.defaultID`），决定后立即写入、之后不再判断
/// - 读到未知 id（目录删了这个模型）、隐藏的或不适用于这个用途的 id 时，退回该用途的默认值并写入
/// - “不用”（只有 `ModelRole.allowsNone` 的用途可以）存成 `"none"`
@MainActor @Observable
public final class ModelSelections {
    public let catalog: ModelCatalog
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let isExistingInstall: () -> Bool
    /// 各用途当前的选择（nil 是“不用”）。读的时候才决定默认值，所以不在 init 里填
    private var resolved: [ModelRole: String?] = [:]
    @ObservationIgnored private var observers: [@MainActor (ModelRole) -> Void] = []

    static let noneValue = "none"

    /// - Parameter isExistingInstall: 是否已有安装（会议目录里已有会议），决定会后转写和纪要的默认值。
    ///   只在某个用途第一次需要默认值时调用
    public init(defaults: UserDefaults = .standard, catalog: ModelCatalog = .builtIn,
                isExistingInstall: @escaping () -> Bool) {
        self.defaults = defaults
        self.catalog = catalog
        self.isExistingInstall = isExistingInstall
    }

    /// App 启动时建：会议目录里已有会议的视为已有安装。每个用途没存过选择时当场决定默认值并写入，
    /// 免得第一场会议录完后才决定（那时已经有会议，新安装会被当成已有安装）
    public static func atLaunch(meetings: [Meeting], defaults: UserDefaults = .standard,
                                catalog: ModelCatalog = .builtIn) -> ModelSelections {
        let existingInstall = !meetings.isEmpty
        let selections = ModelSelections(defaults: defaults, catalog: catalog, isExistingInstall: { existingInstall })
        for role in ModelRole.allCases { _ = selections.selectedID(for: role) }
        return selections
    }

    public static func key(for role: ModelRole) -> String { "model.\(role.rawValue)" }

    /// 选中的模型 id；nil 表示“不用”
    public func selectedID(for role: ModelRole) -> String? {
        if let cached = resolved[role] { return cached }
        let id = resolve(role)
        resolved[role] = id
        return id
    }

    /// 选中的目录项；nil 表示“不用”
    public func selected(for role: ModelRole) -> CatalogModel? {
        selectedID(for: role).flatMap { catalog.model(id: $0) }
    }

    /// 选一个模型（nil 是“不用”）。不适用于这个用途的选择不接受
    public func select(_ id: String?, for role: ModelRole) {
        guard isSelectable(id, for: role) else { return }
        let changed = selectedID(for: role) != id
        resolved[role] = id
        defaults.set(id ?? Self.noneValue, forKey: Self.key(for: role))
        if changed { observers.forEach { $0(role) } }
    }

    /// 某个用途的选择变了（在 `select` 里、写入之后同步调用）时调用 `handler`，用来把新选择同步到管线。
    /// 可以有多个：各用途的管线各自订阅、只看自己的用途。选同一个模型不调用
    public func observe(_ handler: @escaping @MainActor (ModelRole) -> Void) {
        observers.append(handler)
    }

    private func isSelectable(_ id: String?, for role: ModelRole) -> Bool {
        guard let id else { return role.allowsNone }
        return catalog.models(for: role).contains { $0.id == id }
    }

    private func resolve(_ role: ModelRole) -> String? {
        if let stored = defaults.string(forKey: Self.key(for: role)) {
            let id = stored == Self.noneValue ? nil : stored
            if isSelectable(id, for: role) { return id }
        }
        let id = catalog.defaultID(for: role, isExistingInstall: isExistingInstall())
        defaults.set(id ?? Self.noneValue, forKey: Self.key(for: role))
        return id
    }
}

/// 目录里需要下载的模型的下载器，每个模型一个，由这里统一创建和管理。
/// 主模型的下载器连同它依赖的（需要下载的）辅助模型一起下；删除主模型时，
/// 还有别的已下载模型依赖的辅助模型保留
@MainActor
public final class ModelDownloads {
    public let catalog: ModelCatalog
    /// 模型根目录（`LocalModel.defaultDirectory`；测试用临时目录）
    public let directory: URL
    private let transport: any ModelTransport
    private var downloaders: [String: ModelDownloader] = [:]

    public init(catalog: ModelCatalog = .builtIn, directory: URL, transport: any ModelTransport) {
        self.catalog = catalog
        self.directory = directory
        self.transport = transport
    }

    /// 模型的下载器；系统自带、已打进 App 的模型为 nil。同一个模型每次拿到的是同一个实例
    public func downloader(for model: CatalogModel) -> ModelDownloader? {
        guard let local = model.download else { return nil }
        if let existing = downloaders[model.id] { return existing }
        let deps = catalog.dependencies(of: model).compactMap(\.download)
        let d = ModelDownloader(model: local, dependencies: deps, directory: directory, transport: transport)
        d.keepsDependency = { [weak self] dep in self?.isNeeded(dep, byOtherThan: model.id) ?? true }
        downloaders[model.id] = d
        return d
    }

    /// 模型能不能用：系统自带、已打进 App 的总是能用；需要下载的看它和辅助模型的文件是否都已下好
    public func isReady(_ model: CatalogModel) -> Bool {
        guard let local = model.download else { return true }
        let deps = catalog.dependencies(of: model).compactMap(\.download)
        return ([local] + deps).allSatisfy { $0.isDownloaded(in: directory) }
    }

    /// 除了 `id` 以外，还有已下载的模型依赖这个辅助模型
    private func isNeeded(_ dependency: LocalModel, byOtherThan id: String) -> Bool {
        catalog.models.contains { other in
            other.id != id && other.dependencies.contains(dependency.id)
                && (other.download?.isDownloaded(in: directory) ?? false)
        }
    }
}

extension ModelSelections {
    /// 现在选着这个模型的用途（按 `ModelRole.allCases` 的顺序）。同一份模型文件可能同时是几个用途的模型
    public func roles(selecting model: CatalogModel) -> [ModelRole] {
        ModelRole.allCases.filter { selectedID(for: $0) == model.id }
    }
}

/// 删除模型前确认框里的说明
public enum ModelDeletion {
    /// 释放多少空间，和删除后对现在选着它的各用途的影响（`ModelSelections.roles(selecting:)`）。
    /// 按用途说，不按是从哪个选择框删的：Paraformer、Fun-ASR-Nano 是会后转写和实时字幕定稿共用的文件
    /// - Parameter size: 要释放的大小的文字（如“2.1 GB”）
    public static func message(size: String, selectedFor roles: [ModelRole]) -> String {
        let head = "释放约 \(size) 空间。"
        guard !roles.isEmpty else { return head + "现在没有用途选着它。" }
        let effects = roles.map(\.deletionEffect).joined(separator: "；")
        let notes = roles.compactMap(\.deletionNote).joined()
        return head + "删除后，" + effects + "。" + notes
    }
}

private extension ModelRole {
    /// 删了所选模型、重新下载前，这个用途会怎样
    var deletionEffect: String {
        switch self {
        case .transcription: "新的会议会等待重新下载再转写"
        case .liveCaptions: "实时字幕改用 SpeechAnalyzer（系统自带），直到重新下载"
        // 实时字幕定稿可以不用：没有模型就不做，不排队
        case .liveFinalize: "重新下载前不做实时字幕定稿，字幕照常显示"
        case .minutes: "新的纪要会等待重新下载"
        case .voiceprint: "新的会议要等重新下载后才区分说话人"
        }
    }

    /// 已有的结果不受影响的说明
    var deletionNote: String? {
        switch self {
        case .minutes: "已生成的纪要不受影响。"
        case .voiceprint: "已有会议的说话人不受影响。"
        case .transcription, .liveCaptions, .liveFinalize: nil
        }
    }
}
