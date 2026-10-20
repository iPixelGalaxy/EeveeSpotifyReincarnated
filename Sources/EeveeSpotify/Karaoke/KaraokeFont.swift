import SwiftUI
import CoreText
import CryptoKit

/// Download once, register for this process, and keep the chosen font across launches.
final class KaraokeFont: ObservableObject {
    static let shared = KaraokeFont()
    @Published private(set) var revision = 0
    @Published private(set) var status = ""
    @Published private(set) var loading = false
    @Published private(set) var failed = false
    private var postscriptName: String?
    private var requested: String?
    private var generation = 0
    private var task: URLSessionDownloadTask?
    private let queue = DispatchQueue(label: "com.eevee.karaoke.font", qos: .userInitiated)
    private enum FontError: Error { case invalid }

    func font(ofSize size: CGFloat, fallback: UIFont? = nil) -> UIFont {
        if let postscriptName, let font = UIFont(name: postscriptName, size: size) { return font }
        return fallback ?? UIFont.systemFont(ofSize: size, weight: .bold)
    }

    func configure(_ options: KaraokeOptions, force: Bool = false) {
        let text = options.customFontURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard options.customFontEnabled else {
            task?.cancel(); task = nil
            generation += 1; requested = nil
            loading = false; failed = false; status = ""
            if postscriptName != nil { postscriptName = nil; revision += 1 }
            return
        }
        guard requested != text || force else { return }
        task?.cancel()
        generation += 1
        let token = generation
        requested = text
        loading = false; failed = false; status = ""
        guard !text.isEmpty else { return }
        guard let url = URL(string: text), ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil else {
            failed = true; status = "karaoke_font_invalid_url".localized
            return
        }
        loading = true
        status = "karaoke_font_loading".localized
        do {
            let file = try cacheURL(for: url)
            if FileManager.default.fileExists(atPath: file.path) {
                queue.async { [weak self] in
                    guard let self else { return }
                    let result = Result { try self.register(file) }
                    if case .failure = result { try? FileManager.default.removeItem(at: file) }
                    self.finish(result, token: token)
                }
                return
            }
            var request = URLRequest(url: url)
            request.timeoutInterval = 30
            let download = URLSession.shared.downloadTask(with: request) { [weak self] location, response, error in
                guard let self else { return }
                let result = Result<String, Error> {
                    guard error == nil, let location, let response = response as? HTTPURLResponse,
                          (200...299).contains(response.statusCode) else { throw FontError.invalid }
                    let size = try location.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                    guard size > 0, size <= 32 * 1024 * 1024 else { throw FontError.invalid }
                    if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
                    try FileManager.default.moveItem(at: location, to: file)
                    do { return try self.register(file) }
                    catch { try? FileManager.default.removeItem(at: file); throw error }
                }
                self.finish(result, token: token)
            }
            task = download
            download.resume()
        } catch { finish(.failure(error), token: token) }
    }

    private func cacheURL(for url: URL) throws -> URL {
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("EeveeLyricsFonts", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let key = SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        return root.appendingPathComponent(key).appendingPathExtension(url.pathExtension.lowercased() == "otf" ? "otf" : "ttf")
    }

    private func register(_ file: URL) throws -> String {
        guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(file as CFURL) as? [CTFontDescriptor],
              let descriptor = descriptors.first,
              let name = CTFontDescriptorCopyAttribute(descriptor, kCTFontNameAttribute) as? String else { throw FontError.invalid }
        var error: Unmanaged<CFError>?
        if !CTFontManagerRegisterFontsForURL(file as CFURL, .process, &error) {
            guard let failure = error?.takeRetainedValue(),
                  CFErrorGetCode(failure) == Int(CTFontManagerError.alreadyRegistered.rawValue) else { throw FontError.invalid }
        }
        return name
    }

    private func finish(_ result: Result<String, Error>, token: Int) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.generation == token else { return }
            self.task = nil; self.loading = false
            switch result {
            case .success(let name):
                self.postscriptName = name
                self.failed = false
                self.status = String(format: "karaoke_font_loaded".localized, name)
                self.revision += 1
            case .failure:
                self.failed = true
                self.status = "karaoke_font_failed".localized
            }
        }
    }
}
