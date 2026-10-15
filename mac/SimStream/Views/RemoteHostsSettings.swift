import SwiftUI

/// Settings › Remote Macs: Macs reachable with `ssh <host>` (key auth) whose simulators SimStream can share.
struct RemoteHostsSettings: View {
  @Environment(RemoteCatalog.self) private var remotes
  @State private var name = ""
  @State private var sshHost = ""

  var body: some View {
    Form {
      Section {
        if remotes.hosts.isEmpty {
          Text("No remote Macs yet.").foregroundStyle(.secondary)
        }
        ForEach(remotes.hosts) { host in
          LabeledContent {
            Button("Remove", role: .destructive) { remotes.remove(host) }
              .buttonStyle(.borderless)
          } label: {
            Label {
              VStack(alignment: .leading) {
                Text(host.name)
                Text(host.sshHost).font(.caption.monospaced()).foregroundStyle(.secondary)
              }
            } icon: {
              Image(systemName: "macmini")
            }
          }
        }
      } header: {
        Text("Remote Macs")
      } footer: {
        Text("SimStream copies its command-line tool to each Mac and runs shares there, so a link stays live when this Mac sleeps. The remote Mac needs Xcode, cloudflared, and SSH key login.")
      }

      Section("Add a Mac") {
        TextField("Name", text: $name, prompt: Text("Mac mini"))
        TextField("SSH host", text: $sshHost, prompt: Text("host alias or user@host"))
          .font(.body.monospaced())
        Button("Add") {
          remotes.add(RemoteHost(name: name.isEmpty ? sshHost : name, sshHost: sshHost.trimmingCharacters(in: .whitespaces)))
          name = ""
          sshHost = ""
        }
        .disabled(sshHost.trimmingCharacters(in: .whitespaces).isEmpty)
      }
    }
    .formStyle(.grouped)
    .frame(width: 460)
    .fixedSize(horizontal: false, vertical: true)
  }
}
