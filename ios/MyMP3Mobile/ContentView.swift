import Combine
import Foundation
import SwiftUI

final class MacServiceDiscovery: NSObject, ObservableObject, NetServiceBrowserDelegate, NetServiceDelegate {
    @Published private(set) var baseURL: URL?
    @Published private(set) var status = "Mac의 My MP3 앱을 찾는 중…"

    private let browser = NetServiceBrowser()
    private var services: [NetService] = []

    override init() {
        super.init()
        browser.delegate = self
    }

    func start() {
        guard baseURL == nil else { return }
        browser.includesPeerToPeer = true
        browser.searchForServices(ofType: "_mymp3._tcp.", inDomain: "local.")
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        services.append(service)
        service.delegate = self
        service.resolve(withTimeout: 5)
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        guard let host = sender.hostName?.trimmingCharacters(in: CharacterSet(charactersIn: ".")),
              let url = URL(string: "http://\(host):\(sender.port)") else { return }
        DispatchQueue.main.async {
            self.baseURL = url
            self.status = "Mac과 연결됨"
        }
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        DispatchQueue.main.async {
            self.status = "Mac 연결을 확인해 주세요"
        }
    }
}

@MainActor
final class ConverterViewModel: ObservableObject {
    @Published var videoURL = ""
    @Published var rightsConfirmed = false
    @Published var isWorking = false
    @Published var message = ""
    @Published var savedFile: URL?
    @Published private(set) var savedFiles: [URL] = []

    private struct ConvertRequest: Encodable {
        let url: String
        let rightsConfirmed: Bool
    }

    private struct ConvertResponse: Decodable {
        let filename: String
        let downloadUrl: String
    }

    private struct ErrorResponse: Decodable {
        let error: String
    }

    func convert(using baseURL: URL?) async {
        guard let baseURL else {
            message = "Mac에서 My MP3 앱을 먼저 실행해 주세요."
            return
        }
        guard let token = loadToken() else {
            message = "개인 연결 토큰을 읽을 수 없습니다."
            return
        }
        guard let endpoint = URL(string: "/api/convert", relativeTo: baseURL)?.absoluteURL else {
            message = "Mac 연결 주소가 올바르지 않습니다."
            return
        }

        isWorking = true
        savedFile = nil
        message = "Mac에서 오디오를 변환하고 있습니다…"
        defer { isWorking = false }

        do {
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(token, forHTTPHeaderField: "X-MyMP3-Token")
            request.httpBody = try JSONEncoder().encode(
                ConvertRequest(url: videoURL, rightsConfirmed: rightsConfirmed)
            )

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw URLError(.badServerResponse)
            }
            guard (200..<300).contains(http.statusCode) else {
                let detail = try? JSONDecoder().decode(ErrorResponse.self, from: data)
                message = detail?.error ?? "변환 요청에 실패했습니다."
                return
            }

            let result = try JSONDecoder().decode(ConvertResponse.self, from: data)
            guard let downloadURL = URL(string: result.downloadUrl, relativeTo: baseURL)?.absoluteURL else {
                message = "다운로드 주소가 올바르지 않습니다."
                return
            }

            var downloadRequest = URLRequest(url: downloadURL)
            downloadRequest.setValue(token, forHTTPHeaderField: "X-MyMP3-Token")
            let (temporaryURL, downloadResponse) = try await URLSession.shared.download(for: downloadRequest)
            guard let downloadHTTP = downloadResponse as? HTTPURLResponse,
                  (200..<300).contains(downloadHTTP.statusCode) else {
                throw URLError(.badServerResponse)
            }

            let destination = uniqueDestination(for: result.filename)
            try FileManager.default.moveItem(at: temporaryURL, to: destination)
            savedFile = destination
            refreshSavedFiles()
            message = "저장 완료: \(destination.lastPathComponent)"
        } catch {
            message = "실패: \(error.localizedDescription)"
        }
    }

    private func loadToken() -> String? {
        guard let url = Bundle.main.url(forResource: "remote-token", withExtension: "txt"),
              let value = try? String(contentsOf: url, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }

    func refreshSavedFiles() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .isRegularFileKey]
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: documents,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        )) ?? []

        savedFiles = urls
            .filter { url in
                guard url.pathExtension.lowercased() == "mp3",
                      let values = try? url.resourceValues(forKeys: keys) else { return false }
                return values.isRegularFile == true
            }
            .sorted { left, right in
                let leftDate = (try? left.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                let rightDate = (try? right.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                return leftDate > rightDate
            }
            .prefix(5)
            .map { $0 }
    }

    private func uniqueDestination(for filename: String) -> URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let original = documents.appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: original.path) else { return original }

        let stem = original.deletingPathExtension().lastPathComponent
        let ext = original.pathExtension
        for number in 2...999 {
            let candidate = documents.appendingPathComponent("\(stem) (\(number)).\(ext)")
            if !FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return documents.appendingPathComponent("\(stem)-\(UUID().uuidString).\(ext)")
    }
}

struct ContentView: View {
    @StateObject private var discovery = MacServiceDiscovery()
    @StateObject private var model = ConverterViewModel()
    @State private var savedListExpanded = false

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.08, green: 0.08, blue: 0.075), .black],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text("LOCAL AUDIO CONVERTER")
                        .font(.caption.bold())
                        .tracking(2)
                        .foregroundStyle(Color(red: 1, green: 0.36, blue: 0.24))

                    Text("영상의 소리를\n간단하게 MP3로.")
                        .font(.system(size: 42, weight: .bold, design: .rounded))
                        .tracking(-2)
                        .foregroundStyle(.white)

                    Label(discovery.status, systemImage: discovery.baseURL == nil ? "macbook.and.iphone" : "checkmark.circle.fill")
                        .font(.subheadline.weight(.semibold))
                    .foregroundStyle(discovery.baseURL == nil ? Color.secondary : Color.green)

                    VStack(alignment: .leading, spacing: 16) {
                        Text("YouTube 영상 주소")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        TextField("https://www.youtube.com/watch?v=…", text: $model.videoURL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                            .padding(16)
                            .background(.black.opacity(0.28), in: RoundedRectangle(cornerRadius: 14))

                        Toggle("이 콘텐츠를 변환할 권한이 있습니다.", isOn: $model.rightsConfirmed)
                            .tint(Color(red: 1, green: 0.31, blue: 0.20))
                            .font(.footnote)

                        Button {
                            Task { await model.convert(using: discovery.baseURL) }
                        } label: {
                            HStack {
                                if model.isWorking { ProgressView().tint(.white) }
                                Text(model.isWorking ? "변환 중…" : "MP3 변환")
                                    .fontWeight(.bold)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.white)
                        .background(Color(red: 1, green: 0.31, blue: 0.20), in: RoundedRectangle(cornerRadius: 14))
                        .disabled(model.videoURL.isEmpty || !model.rightsConfirmed || model.isWorking || discovery.baseURL == nil)
                        .opacity(model.videoURL.isEmpty || !model.rightsConfirmed || discovery.baseURL == nil ? 0.55 : 1)
                    }
                    .padding(20)
                    .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 22))
                    .overlay(RoundedRectangle(cornerRadius: 22).stroke(.white.opacity(0.12)))

                    if !model.message.isEmpty {
                        Text(model.message)
                            .font(.subheadline)
                            .foregroundStyle(model.message.hasPrefix("실패") ? .red : .secondary)
                    }

                    if let file = model.savedFile {
                        ShareLink(item: file) {
                            Label("파일 열기·공유", systemImage: "square.and.arrow.up")
                                .fontWeight(.semibold)
                        }
                        .foregroundStyle(Color(red: 1, green: 0.45, blue: 0.36))
                    }

                    VStack(spacing: 0) {
                        Button {
                            model.refreshSavedFiles()
                            withAnimation(.easeInOut(duration: 0.18)) {
                                savedListExpanded.toggle()
                            }
                        } label: {
                            HStack(spacing: 12) {
                                Label("저장 완료", systemImage: "tray.full.fill")
                                    .fontWeight(.semibold)
                                Spacer()
                                Text("최신 5개")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Image(systemName: "chevron.down")
                                    .foregroundStyle(Color(red: 1, green: 0.45, blue: 0.36))
                                    .rotationEffect(.degrees(savedListExpanded ? 180 : 0))
                            }
                            .contentShape(Rectangle())
                            .padding(18)
                        }
                        .buttonStyle(.plain)

                        if savedListExpanded {
                            Divider().overlay(.white.opacity(0.12))

                            if model.savedFiles.isEmpty {
                                Text("저장된 MP3가 없습니다.")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(18)
                            } else {
                                VStack(spacing: 0) {
                                    ForEach(model.savedFiles, id: \.path) { file in
                                        ShareLink(item: file) {
                                            HStack(spacing: 12) {
                                                Image(systemName: "music.note")
                                                    .foregroundStyle(Color(red: 1, green: 0.45, blue: 0.36))
                                                Text(file.lastPathComponent)
                                                    .font(.subheadline)
                                                    .lineLimit(1)
                                                Spacer()
                                                Image(systemName: "square.and.arrow.up")
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                            }
                                            .padding(.horizontal, 18)
                                            .padding(.vertical, 14)
                                        }
                                        .buttonStyle(.plain)

                                        if file != model.savedFiles.last {
                                            Divider().overlay(.white.opacity(0.08))
                                                .padding(.leading, 48)
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 18))
                    .overlay(RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(0.12)))

                    Text("Mac의 My MP3 앱이 실행 중이고 같은 Wi‑Fi에 연결되어 있어야 합니다. 파일은 나의 iPhone > My MP3에 저장됩니다.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineSpacing(4)
                }
                .padding(24)
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            discovery.start()
            model.refreshSavedFiles()
        }
    }
}
