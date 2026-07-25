import SwiftUI
import UniformTypeIdentifiers

struct AddServerView: View {
    enum Mode {
        case add
        case edit(ServerProfile)
    }

    enum Field: Hashable {
        case name, host, port, username, password, privateKey
    }

    let mode: Mode
    /// profile, password (password auth), importedKeyURL (private key auth)
    var onSave: (ServerProfile, String?, URL?) throws -> Void

    @Environment(\.dismiss) private var dismiss
    @FocusState private var focusedField: Field?
    @State private var name = ""
    @State private var host = ""
    @State private var port = "22"
    @State private var username = ""
    @State private var authMethod: AuthMethod = .password
    @State private var password = ""
    @State private var privateKeyLabel = ""
    @State private var importedKeyURL: URL?
    @State private var showImporter = false
    @State private var errorText: String?
    @State private var existingID: UUID?
    @State private var keepExistingKey = false

    var body: some View {
        NavigationStack {
            formBody
                .padding(24)
                #if os(macOS)
                .frame(minWidth: 480, minHeight: 420)
                #endif
                .navigationTitle(title)
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("保存") { save() }
                    }
                }
        }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.data, .plainText, .item],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                importedKeyURL = url
                privateKeyLabel = url.lastPathComponent
                keepExistingKey = false
            case .failure(let error):
                errorText = error.localizedDescription
            }
        }
        .onAppear {
            load()
            AppBootstrap.focusKeyWindow()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                focusedField = .host
            }
        }
    }

    private var formBody: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 12) {
                labeledField("名称（可选）") {
                    TextField("名称", text: $name)
                        .textFieldStyle(.roundedBorder)
                        .focused($focusedField, equals: .name)
                }
                labeledField("主机") {
                    TextField("IP 或域名", text: $host)
                        .textFieldStyle(.roundedBorder)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                        #endif
                        .focused($focusedField, equals: .host)
                }
                labeledField("端口") {
                    TextField("22", text: $port)
                        .textFieldStyle(.roundedBorder)
                        #if os(iOS)
                        .keyboardType(.numberPad)
                        #endif
                        .focused($focusedField, equals: .port)
                }
                labeledField("用户名") {
                    TextField("ubuntu", text: $username)
                        .textFieldStyle(.roundedBorder)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        #endif
                        .focused($focusedField, equals: .username)
                }
                labeledField("认证方式") {
                    Picker("", selection: $authMethod) {
                        ForEach(AuthMethod.allCases) { method in
                            Text(method.title).tag(method)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                }
                if authMethod == .password {
                    labeledField(passwordPlaceholder) {
                        SecureField("密码", text: $password)
                            .textFieldStyle(.roundedBorder)
                            .focused($focusedField, equals: .password)
                    }
                } else {
                    labeledField("私钥文件") {
                        HStack {
                            Text(privateKeyLabel.isEmpty ? "未选择" : privateKeyLabel)
                                .foregroundStyle(privateKeyLabel.isEmpty ? .secondary : .primary)
                                .lineLimit(1)
                            Spacer()
                            Button("选择…") { showImporter = true }
                        }
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
                    }
                }
            }

            if let errorText {
                Text(errorText)
                    .foregroundStyle(.red)
                    .font(.callout)
            }

            Spacer(minLength: 0)
        }
    }

    private func labeledField<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            content()
        }
    }

    private var title: String {
        switch mode {
        case .add: return "添加服务器"
        case .edit: return "编辑服务器"
        }
    }

    private var passwordPlaceholder: String {
        if case .edit = mode { return "密码（留空则不修改）" }
        return "密码"
    }

    private func load() {
        if case .edit(let s) = mode {
            existingID = s.id
            name = s.name
            host = s.host
            port = String(s.port)
            username = s.username
            authMethod = s.authMethod
            if s.authMethod == .privateKey {
                privateKeyLabel = (s.credentialRef as NSString).lastPathComponent
                keepExistingKey = true
            }
        }
    }

    private func save() {
        errorText = nil
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedUser = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty, !trimmedUser.isEmpty else {
            errorText = "请填写主机和用户名"
            return
        }
        guard let portValue = Int(port), (1...65535).contains(portValue) else {
            errorText = "端口无效"
            return
        }

        let id = existingID ?? UUID()
        var profile = ServerProfile(
            id: id,
            name: name,
            host: trimmedHost,
            port: portValue,
            username: trimmedUser,
            authMethod: authMethod,
            credentialRef: ""
        )

        if authMethod == .password {
            if case .add = mode, password.isEmpty {
                errorText = "请输入密码"
                return
            }
        } else {
            if importedKeyURL == nil && !keepExistingKey {
                errorText = "请选择私钥文件"
                return
            }
            if keepExistingKey, case .edit(let s) = mode {
                profile.credentialRef = s.credentialRef
            }
        }

        do {
            try onSave(profile, authMethod == .password ? password : nil, importedKeyURL)
            dismiss()
        } catch {
            errorText = error.localizedDescription
        }
    }
}
