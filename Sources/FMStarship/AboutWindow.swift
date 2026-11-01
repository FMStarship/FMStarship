import SwiftUI

struct AboutWindow: View {
    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "27.0.2"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("FM Starship \(version)").font(.title2.weight(.semibold))
                Text("A scouting tool for Football Manager. It reads your running save - every attribute, the hidden ones included, exact CA/PA, personality, traits, role ratings, season stats, injuries and who would join you - straight from the game's own data. Plus a squad planner, a bargain finder, comparisons and FM shortlists both ways.")
                Text("Read-only: it never changes the game or your save.")

                Divider()
                Text("An unofficial Mac port").font(.headline)
                Text("FM Starship is an unofficial Mac port of FM Moleman for Windows, and much of it still comes from there. FM Moleman's features, its research into the game and its way of reading FM are the work of its author, who doesn't make or support this version. Please report problems with FM Starship to FM Starship, not to MCM Gaming.")
                Text("Credit: MCM Gaming (FM Moleman). FM Moleman is free. If you find this useful, you can buy its author a coffee.")
                Link("FM Moleman", destination: URL(string: "https://sortitoutsi.net/content/78068/fm-moleman-27")!)
                Link("MCM Gaming (FM Moleman) on Ko-fi", destination: URL(string: "https://ko-fi.com/mcmgaming")!)

                Divider()
                Text("Not affiliated with or endorsed by Sports Interactive or SEGA. Football Manager is a trademark of Sports Interactive Ltd. No game files or data are included.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                Divider()
                Text("Licence").font(.headline)
                Text("FM Starship is free for noncommercial use under the PolyForm Noncommercial License 1.0.0. You can read, use and change it, but not sell it.")
                Link("Read the licence", destination: URL(string: "https://polyformproject.org/licenses/noncommercial/1.0.0")!)
                Text("Required Notice: Copyright (c) 2026 Markus Skov\nRequired Notice: Includes work from FM Moleman, Copyright (c) 2026 MCM Gaming (https://ko-fi.com/mcmgaming), used with permission")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)

                Divider()
                Text("Third-party notices").font(.headline)
                Text(Self.notices)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
        .frame(width: 520, height: 560)
    }

    /// Zstandard is the only code in this build from anywhere else. It's linked statically, so its licence travels with the app.
    private static let notices = """
    FM Starship uses Zstandard - https://github.com/facebook/zstd

    BSD License. Copyright (c) Meta Platforms, Inc. and affiliates. All rights reserved.

    Redistribution and use in source and binary forms, with or without modification, are permitted provided that the following conditions are met:

    * Redistributions of source code must retain the above copyright notice, this list of conditions and the following disclaimer.

    * Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the following disclaimer in the documentation and/or other materials provided with the distribution.

    * Neither the name Facebook, nor Meta, nor the names of its contributors may be used to endorse or promote products derived from this software without specific prior written permission.

    THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
    """
}
