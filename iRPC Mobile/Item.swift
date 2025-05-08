//
//  Item.swift
//  iRPC Mobile
//
//  Created by Adrian Castro on 8/5/25.
//

import Foundation
import SwiftData

@Model
final class Item {
    var timestamp: Date
    
    init(timestamp: Date) {
        self.timestamp = timestamp
    }
}
