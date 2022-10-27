//
//  AnnotationSliderViewController.swift
//  Zotero
//
//  Created by Michal Rentka on 07.09.2021.
//  Copyright © 2021 Corporation for Digital Scholarship. All rights reserved.
//

import UIKit

import RxSwift

#if PDFENABLED

class AnnotationSliderViewController: UIViewController {
    private let titleString: String
    private let initialValue: Float
    private let valueChanged: (CGFloat) -> Void
    private let disposeBag: DisposeBag

    init(title: String, initialValue: CGFloat, valueChanged: @escaping (CGFloat) -> Void) {
        self.titleString = title
        self.initialValue = Float(initialValue)
        self.valueChanged = valueChanged
        self.disposeBag = DisposeBag()
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let view = UIView()
        view.backgroundColor = .white
        self.view = view
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        self.setupView()
        self.setupNavigationBar()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        self.preferredContentSize = CGSize(width: 300, height: 58)
    }

    private func setupView() {
        let view = LineWidthView(title: self.titleString, settings: .lineWidth)
        view.translatesAutoresizingMaskIntoConstraints = false
        view.value = self.initialValue
        view.valueObservable
            .subscribe(with: self, onNext: { `self`, value in
                self.valueChanged(CGFloat(value))
            })
            .disposed(by: self.disposeBag)
        self.view.addSubview(view)

        let verticalConstraint: NSLayoutConstraint

        if UIDevice.current.userInterfaceIdiom == .pad {
            verticalConstraint = self.view.safeAreaLayoutGuide.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        } else {
            verticalConstraint = view.topAnchor.constraint(equalTo: self.view.safeAreaLayoutGuide.topAnchor, constant: 15)
        }

        NSLayoutConstraint.activate([
            verticalConstraint,
            self.view.safeAreaLayoutGuide.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            self.view.safeAreaLayoutGuide.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
    }

    private func setupNavigationBar() {
        guard UIDevice.current.userInterfaceIdiom == .phone else { return }

        let appearance = UINavigationBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = .white
        self.navigationController?.navigationBar.standardAppearance = appearance
        self.navigationController?.navigationBar.scrollEdgeAppearance = appearance

        let doneButton = UIBarButtonItem(barButtonSystemItem: .done, target: nil, action: nil)
        doneButton.rx.tap.subscribe(onNext: { [weak self] _ in
            self?.navigationController?.presentingViewController?.dismiss(animated: true)
        })
        .disposed(by: self.disposeBag)
        self.navigationItem.rightBarButtonItem = doneButton
    }
}

#endif
