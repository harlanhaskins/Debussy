//
//  File.swift
//  
//
//  Created by Harlan Haskins on 3/27/24.
//

import Foundation
import CoreGraphics
import CoreText
import SwiftUI

extension Color {
    init(hue: Double, saturation: Double, lightness: Double, opacity: Double) {
        precondition(0...1 ~= hue &&
                     0...1 ~= saturation &&
                     0...1 ~= lightness &&
                     0...1 ~= opacity, "input range is out of range 0...1")

        //From HSL TO HSB ---------
        var newSaturation: Double = 0.0

        let brightness = lightness + saturation * min(lightness, 1-lightness)

        if brightness == 0 { newSaturation = 0.0 }
        else {
            newSaturation = 2 * (1 - lightness / brightness)
        }
        //---------

        self.init(hue: hue, saturation: newSaturation, brightness: brightness, opacity: opacity)
    }

    static var darkBackground: Color {
        Color(red: 0.18, green: 0.18, blue: 0.167)
    }

    static var lightBackground: Color {
        Color(red: 241/255, green: 240/255, blue: 233/255)
    }

    static var darkReceivedMessageBackground: Color {
        Color(red: 57/255, green: 57/255, blue: 55/255)
    }

    static var darkSentMessageBackground: some ShapeStyle {
        let start = Color(red: 33/255, green: 32/255, blue: 28/255)
        let end = Color(red: 26/255, green: 25/255, blue: 21/255)
        return LinearGradient(colors: [start, end], startPoint: .top, endPoint: .bottom)
    }

    static var lightSentMessageBackground: some ShapeStyle {
        let start = Color(red: 232/255, green: 229/255, blue: 216/255)
        let end = Color(red: 222/255, green: 216/255, blue: 196/255)
        return LinearGradient(colors: [start, end], startPoint: .top, endPoint: .bottom)
    }

    static var lightReceivedMessageBackground: Color {
        Color(red: 248/255, green: 248/255, blue: 247/255)
    }

    static var lightBorder: Color {
        Color(red: 112/255, green: 107/255, blue: 87/255, opacity: 0.25)
    }

    static var darkBorder: Color {
        Color(red: 108/255, green: 106/255, blue: 96/255, opacity: 0.25)
    }

    static var claudeOrange: Color {
        Color(red: 204/255, green: 93/255, blue: 52/255)
    }
}

func registerFonts() {
    // Custom fonts removed - using system fonts
}
