// Bridges MailyCore.KeyboardShortcut into a non-ambiguous name for files that
// also import SwiftUI (which declares its own KeyboardShortcut). This file
// deliberately does not import SwiftUI.
import MailyCore

typealias CoreShortcut = KeyboardShortcut
typealias CoreModifiers = Modifiers
