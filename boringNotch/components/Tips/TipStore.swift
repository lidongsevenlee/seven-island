//
//  TipStore.swift
//  boringNotch
//
//  Created by Richard Kunkli on 15/09/2024.
//

import SwiftUI
import TipKit

struct HUDsTip: Tip {
    var title: Text {
        Text("使用 HUD 提升体验")
    }
    
    
    var message: Text? {
        Text("解锁高级功能，改善使用体验。立即升级以获得更多自定义选项！")
    }
    
    
    var image: Image? {
        AppIcon(for: "com.local.seven-island")
    }
    
    var actions: [Action] {
        Action {
            Text("了解更多")
        }
    }
}

struct CBTip: Tip {
    var title: Text {
        Text("使用剪贴板管理器提升效率")
    }
    
    
    var message: Text? {
        Text("轻松复制、存储和管理最常用的内容。立即升级以获得多项目存储和快速访问等高级功能！")
    }
    
    
    var image: Image? {
        AppIcon(for: "com.local.seven-island")
    }
    
    var actions: [Action] {
        Action {
            Text("了解更多")
        }
    }
}

struct TipsView: View {
    var hudTip = HUDsTip()
    var cbTip = CBTip()
    var body: some View {
        VStack {
            TipView(hudTip)
            TipView(cbTip)
        }
        .task {
            try? Tips.configure([
                .displayFrequency(.immediate),
                .datastoreLocation(.applicationDefault)
            ])
        }
    }
}

#Preview {
    TipsView()
}
