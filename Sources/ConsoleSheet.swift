import SwiftUI

/// Serial console for the guest.
///
/// The frontend hosts a real terminal (xterm.js), which is where the guest is
/// normally driven. This sheet deliberately stays a plain text view: it is what
/// is left when the web layer is the thing that is broken, and a fallback that
/// shares code with the primary path is not much of a fallback.
struct ConsoleSheet: View {
    @ObservedObject var model: VMModel
    @Binding var showDiagnostics: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var command = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                console
                Divider()
                inputBar
            }
            .navigationTitle(model.status)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(model.isRunning ? "停止" : "启动") {
                        model.isRunning ? model.stop() : model.start()
                    }
                }
            }
        }
    }

    private var console: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(model.consoleText.isEmpty ? "客户机串口输出会显示在这里。" : model.consoleText)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .id("console-bottom")
            }
            .onChange(of: model.consoleText) { _, _ in
                proxy.scrollTo("console-bottom", anchor: .bottom)
            }
        }
        .background(Color.black.opacity(0.6))
    }

    private var inputBar: some View {
        HStack(spacing: 8) {
            Button("Ctrl-C") { model.writeToConsole(Data([0x03])) }
                .buttonStyle(.bordered)
                .disabled(!model.isRunning)
            TextField("命令", text: $command)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .onSubmit(send)
                .disabled(!model.isRunning)
            Button("发送", action: send)
                .buttonStyle(.borderedProminent)
                .disabled(!model.isRunning || command.isEmpty)
        }
        .padding()
    }

    private func send() {
        guard model.isRunning, !command.isEmpty else { return }
        model.writeToConsole(Data((command + "\n").utf8))
        command = ""
    }
}
