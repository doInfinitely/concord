//
//  ContentView.swift
//  Concord
//
//  Created by Remy Ochei on 10/20/25.
//

import SwiftUI

struct ContentView: View {
    @State private var taps = 0

    var body: some View {
        VStack(spacing: 16) {
            Text("Hello, Concord 👋")
                .font(.largeTitle).bold()
            Text("You’ve tapped \(taps) time\(taps == 1 ? "" : "s").")
                .font(.headline).opacity(0.7)

            Button {
                taps += 1
            } label: {
                Text("Tap me")
                    .padding(.vertical, 12)
                    .padding(.horizontal, 20)
                    .background(.blue)
                    .foregroundStyle(.white)
                    .clipShape(Capsule())
                    .shadow(radius: 4)
            }
        }
        .padding()
    }
}

#Preview {
    ContentView()
}

