//
//  WhatsNewView.swift
//  boringNotch
//
//  Created by Richard Kunkli on 09/08/2024.
//

import SwiftUI

struct WhatsNewView: View {
    @Binding var isPresented: Bool
    
    var body: some View {
        VStack(spacing: 20) {
            Text("新功能")
                .font(.largeTitle)

            VStack(alignment: .leading, spacing: 10) {
                Text("• 新功能 1")
                Text("• 性能改进")
                Text("• 问题修复")
            }

            Button("知道了") {
                isPresented = false
            }
        }
        .frame(width: 300, height: 200)
        .padding()
    }
}

#Preview {
    WhatsNewView(isPresented: .constant(true))
}
