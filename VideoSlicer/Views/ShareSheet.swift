import SwiftUI
import UIKit

struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]
    /// Subject passed to `UIActivityViewController.setValue(_:forKey: "subject")`
    /// for activities that surface a subject line (Mail, Messages). Activities
    /// that ignore the subject (AirDrop, Save to Files) use the filename of
    /// the shared URL instead — so callers should also pre-stage the file
    /// with a friendly name.
    var subject: String?
    var completion: UIActivityViewController.CompletionWithItemsHandler?

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(
            activityItems: activityItems,
            applicationActivities: nil
        )
        controller.completionWithItemsHandler = completion
        if let subject, !subject.isEmpty {
            // `setValue(_:forKey:)` with the "subject" key is the only public
            // hook for setting the subject — there's no dedicated property
            // on `UIActivityViewController` as of iOS 17.
            controller.setValue(subject, forKey: "subject")
        }
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}