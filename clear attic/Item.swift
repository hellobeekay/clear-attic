//
//  Item.swift
//  clear attic
//
//  Created by Balaji K on 03/04/26.
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
