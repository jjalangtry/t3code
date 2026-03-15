import AVFoundation
import Combine
import PhotosUI
import Speech
import SwiftUI

// MARK: - Composer Text Field

struct ComposerTextField: View {
    let placeholder: String
    @Binding var text: String
    let canSend: Bool
    let isRunning: Bool
    let onSend: () -> Void
    let onStop: () -> Void

    @FocusState private var isTextFieldFocused: Bool
    @StateObject private var speechRecognizer = SpeechRecognizer()

    private var showSendButton: Bool {
        canSend || isRunning
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField(placeholder, text: $text, axis: .vertical)
                .font(.body)
                .textFieldStyle(.plain)
                .lineLimit(1...6)
                .focused($isTextFieldFocused)
                .padding(.vertical, 12)

            if isRunning {
                Button(action: onStop) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .background(Color.red)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .padding(.bottom, 6)
                .transition(.scale.combined(with: .opacity))
            } else if canSend {
                Button(action: onSend) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .background(Color.accentColor)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .padding(.bottom, 6)
                .transition(.scale.combined(with: .opacity))
            } else {
                Button {
                    toggleDictation()
                } label: {
                    Image(systemName: speechRecognizer.isRecording ? "mic.circle.fill" : "mic.fill")
                        .font(.system(size: speechRecognizer.isRecording ? 28 : 18, weight: .medium))
                        .foregroundStyle(speechRecognizer.isRecording ? Color.accentColor : Color.secondary)
                        .frame(width: 32, height: 32)
                        .symbolEffect(.pulse, isActive: speechRecognizer.isRecording)
                }
                .buttonStyle(.plain)
                .padding(.bottom, 6)
                .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, 6)
        .frame(minHeight: 44)
        .modifier(ComposerFieldModifier())
        .animation(.snappy(duration: 0.2), value: showSendButton)
        .animation(.snappy(duration: 0.2), value: speechRecognizer.isRecording)
        .onChange(of: speechRecognizer.transcribedText) { _, newText in
            if !newText.isEmpty {
                text = newText
            }
        }
    }

    private func toggleDictation() {
        if speechRecognizer.isRecording {
            speechRecognizer.stopRecording()
        } else {
            speechRecognizer.startRecording()
        }
    }
}

// MARK: - Speech Recognizer

@MainActor
final class SpeechRecognizer: ObservableObject {
    @Published var transcribedText = ""
    @Published var isRecording = false
    @Published var errorMessage: String?

    private var audioEngine: AVAudioEngine?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let speechRecognizer = SFSpeechRecognizer(locale: Locale.current)

    func startRecording() {
        Task { @MainActor in
            let micAuthorized = await requestMicrophonePermission()
            guard micAuthorized else {
                errorMessage = "Microphone access not authorized"
                return
            }

            let speechAuthorized = await requestSpeechAuthorization()
            guard speechAuthorized else {
                errorMessage = "Speech recognition not authorized"
                return
            }

            beginRecordingSession()
        }
    }

    private func requestMicrophonePermission() async -> Bool {
        await withCheckedContinuation { continuation in
            if #available(iOS 17.0, *) {
                AVAudioApplication.requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            } else {
                AVAudioSession.sharedInstance().requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        }
    }

    private func requestSpeechAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    private func beginRecordingSession() {
        // Cancel any existing task
        recognitionTask?.cancel()
        recognitionTask = nil

        // Configure audio session
        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.setCategory(.record, mode: .measurement, options: .duckOthers)
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            errorMessage = "Failed to configure audio session"
            return
        }

        audioEngine = AVAudioEngine()
        guard let audioEngine = audioEngine else { return }

        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let recognitionRequest = recognitionRequest else { return }

        recognitionRequest.shouldReportPartialResults = true

        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
            self?.recognitionRequest?.append(buffer)
        }

        recognitionTask = speechRecognizer?.recognitionTask(with: recognitionRequest) { [weak self] result, error in
            Task { @MainActor in
                if let result = result {
                    self?.transcribedText = result.bestTranscription.formattedString
                }
                if error != nil || result?.isFinal == true {
                    self?.stopRecording()
                }
            }
        }

        do {
            audioEngine.prepare()
            try audioEngine.start()
            isRecording = true
        } catch {
            errorMessage = "Failed to start audio engine"
            stopRecording()
        }
    }

    func stopRecording() {
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()

        audioEngine = nil
        recognitionRequest = nil
        recognitionTask = nil
        isRecording = false
    }
}

// MARK: - Composer Field Modifier

struct ComposerFieldModifier: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .background(Color.clear)
                .glassEffect(in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        } else {
            content
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(.white.opacity(0.22), lineWidth: 0.7)
                }
                .shadow(color: .black.opacity(0.06), radius: 18, y: 8)
        }
    }
}

// MARK: - Composer Menu Popover

struct ComposerMenuPopoverView: View {
    let thread: OrchestrationThread?
    @Binding var selectedPhotoItems: [PhotosPickerItem]
    let onFileImport: () -> Void
    let onInteractionModeChange: (InteractionMode) -> Void
    let onRuntimeModeChange: (RuntimeMode) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            actionSection("Attachments") {
                PhotosPicker(
                    selection: $selectedPhotoItems,
                    maxSelectionCount: 8,
                    matching: .images
                ) {
                    actionRow("Photos", systemImage: "photo.on.rectangle", detail: nil)
                }
                .buttonStyle(.plain)

                Button(action: onFileImport) {
                    actionRow("Files", systemImage: "paperclip", detail: nil)
                }
                .buttonStyle(.plain)
            }

            Divider()

            actionSection("Conversation") {
                toggleRow(
                    "Plan Mode",
                    systemImage: "list.bullet.clipboard",
                    detail: "Chat when off",
                    isOn: Binding(
                        get: { thread?.interactionMode == .plan },
                        set: { isOn in onInteractionModeChange(isOn ? .plan : .default) }
                    )
                )
            }

            Divider()

            actionSection("Execution") {
                toggleRow(
                    "Full Access",
                    systemImage: "lock.open",
                    detail: "Supervised when off",
                    isOn: Binding(
                        get: { thread?.runtimeMode == .fullAccess },
                        set: { isOn in onRuntimeModeChange(isOn ? .fullAccess : .approvalRequired) }
                    )
                )
            }
        }
        .padding(18)
        .frame(width: 290)
        .modifier(MorphingGlassModifier(cornerRadius: 20))
    }

    @ViewBuilder
    private func actionSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func actionRow(_ title: String, systemImage: String, detail: String?) -> some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .frame(width: 18)
                .foregroundStyle(.primary)
            Text(title)
            Spacer()
            if let detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .background(.white.opacity(0.001), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func toggleRow(
        _ title: String,
        systemImage: String,
        detail: String?,
        isOn: Binding<Bool>
    ) -> some View {
        Toggle(isOn: isOn) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .frame(width: 18)
                    .foregroundStyle(.primary)
                Text(title)
                Spacer()
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .toggleStyle(.switch)
        .tint(.accentColor)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.white.opacity(0.001), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

// MARK: - Morphing Glass Modifier

struct MorphingGlassModifier: ViewModifier {
    let cornerRadius: CGFloat

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .background(Color.clear)
                .glassEffect(in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            content
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
    }
}

// MARK: - Inline Error Banner

struct InlineErrorBanner: View {
    let systemImage: String
    let message: String
    let dismissAction: (() -> Void)?

    init(systemImage: String, message: String, dismissAction: (() -> Void)?) {
        self.systemImage = systemImage
        self.message = message
        self.dismissAction = dismissAction
    }

    var body: some View {
        HStack {
            Image(systemName: systemImage)
            Text(message)
                .font(.caption)
            Spacer()
            if let dismissAction {
                Button(action: dismissAction) {
                    Image(systemName: "xmark")
                        .font(.caption)
                }
            }
        }
        .foregroundStyle(.red)
        .padding(.horizontal)
        .padding(.vertical, 6)
    }
}

// MARK: - Glass Error Banner (for floating overlay)

struct GlassErrorBanner: View {
    let systemImage: String
    let message: String
    let dismissAction: (() -> Void)?

    init(systemImage: String, message: String, dismissAction: (() -> Void)?) {
        self.systemImage = systemImage
        self.message = message
        self.dismissAction = dismissAction
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(.red)
            Text(message)
                .font(.caption)
                .foregroundStyle(.primary)
                .lineLimit(2)
            Spacer()
            if let dismissAction {
                Button(action: dismissAction) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .modifier(GlassErrorBannerModifier())
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }
}

private struct GlassErrorBannerModifier: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .background(.clear)
                .glassEffect(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        } else {
            content
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(.red.opacity(0.3), lineWidth: 0.8)
                }
        }
    }
}

// MARK: - Previews

#Preview("Composer Text Field - Empty") {
    VStack {
        ComposerTextField(
            placeholder: "Message",
            text: .constant(""),
            canSend: false,
            isRunning: false,
            onSend: {},
            onStop: {}
        )
    }
    .padding()
    .background(Color.cyan.opacity(0.2))
}

#Preview("Composer Text Field - With Text") {
    VStack {
        ComposerTextField(
            placeholder: "Message",
            text: .constant("Hello, how can I help?"),
            canSend: true,
            isRunning: false,
            onSend: {},
            onStop: {}
        )
    }
    .padding()
    .background(Color.cyan.opacity(0.2))
}

#Preview("Composer Text Field - Running") {
    VStack {
        ComposerTextField(
            placeholder: "Message",
            text: .constant(""),
            canSend: false,
            isRunning: true,
            onSend: {},
            onStop: {}
        )
    }
    .padding()
    .background(Color.cyan.opacity(0.2))
}

#Preview("Composer Menu Popover") {
    ComposerMenuPopoverView(
        thread: nil,
        selectedPhotoItems: .constant([]),
        onFileImport: {},
        onInteractionModeChange: { _ in },
        onRuntimeModeChange: { _ in }
    )
    .padding()
    .background(Color.cyan.opacity(0.2))
}

#Preview("Inline Error Banner") {
    VStack(spacing: 20) {
        InlineErrorBanner(
            systemImage: "exclamationmark.triangle",
            message: "Something went wrong",
            dismissAction: {}
        )
        
        InlineErrorBanner(
            systemImage: "exclamationmark.octagon",
            message: "Critical error occurred",
            dismissAction: nil
        )
    }
    .background(Color(.systemBackground))
}

#Preview("Glass Error Banner") {
    VStack(spacing: 12) {
        GlassErrorBanner(
            systemImage: "exclamationmark.triangle",
            message: "Connection interrupted",
            dismissAction: {}
        )
        
        GlassErrorBanner(
            systemImage: "exclamationmark.octagon",
            message: "Session error: The operation timed out",
            dismissAction: nil
        )
    }
    .padding()
    .background(Color.black)
}
