//
//  ViewController.swift
//  athenir_prototype
//
//  Created by Will Sloan on 7/23/15.
//  Copyright © 2015 848 Applications and Designs. All rights reserved.
//

import UIKit

class SplashSearchController: UIViewController {
    
    @IBOutlet weak var searchTextBox : UITextField!

    override func viewDidLoad() {
        super.viewDidLoad()
        // Do any additional setup after loading the view, typically from a nib.
    }

    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        // Dispose of any resources that can be recreated.
    }
    
    override func prepareForSegue(segue: UIStoryboardSegue, sender: AnyObject!) {
        if (segue.identifier == "searchSegue") {
            let svc = segue.destinationViewController as! UINavigationController;
            let resultController = svc.childViewControllers[0] as! ResultsViewController
            
            resultController.queryString = searchTextBox.text
        }
    }

}

