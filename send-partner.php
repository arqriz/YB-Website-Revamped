<?php
header('Content-Type: application/json');

if ($_SERVER['REQUEST_METHOD'] !== 'POST') {
    echo json_encode(['success' => false, 'message' => 'Method not allowed.']);
    exit;
}

require 'phpmailer/Exception.php';
require 'phpmailer/PHPMailer.php';
require 'phpmailer/SMTP.php';

use PHPMailer\PHPMailer\PHPMailer;
use PHPMailer\PHPMailer\Exception;

function clean($val) {
    return htmlspecialchars(strip_tags(trim($val ?? '')));
}

$name         = clean($_POST['name'] ?? '');
$email        = clean($_POST['email'] ?? '');
$organisation = clean($_POST['organisation'] ?? '');
$phone        = clean($_POST['phone'] ?? '');
$message      = clean($_POST['message'] ?? '');

if (empty($name) || empty($email) || empty($message)) {
    echo json_encode(['success' => false, 'message' => 'Required fields missing.']);
    exit;
}

if (!filter_var($email, FILTER_VALIDATE_EMAIL)) {
    echo json_encode(['success' => false, 'message' => 'Invalid email address.']);
    exit;
}

$mail = new PHPMailer(true);
try {
    $mail->isSMTP();
    $mail->Host       = 'mail.yellowbin.com.my';
    $mail->SMTPAuth   = true;
    $mail->Username   = 'partnership@yellowbin.com.my';
    $mail->Password   = 'YOUR_EMAIL_PASSWORD_HERE';
    $mail->SMTPSecure = PHPMailer::ENCRYPTION_STARTTLS;
    $mail->Port       = 587;

    $mail->setFrom('partnership@yellowbin.com.my', 'Yellow Bin');
    $mail->addAddress('arif@gamutpro.my');
    $mail->addReplyTo($email, $name);

    $mail->Subject = 'New Partnership Enquiry — ' . $name . ($organisation ? ' (' . $organisation . ')' : '');
    $mail->Body    =
        "New partnership enquiry from the Yellow Bin website.\n\n" .
        "Name:         {$name}\n" .
        "Email:        {$email}\n" .
        "Organisation: " . ($organisation ?: 'Not provided') . "\n" .
        "Phone:        " . ($phone ?: 'Not provided') . "\n\n" .
        "Message:\n{$message}\n\n" .
        "---\nSent from yellowbin.com.my/partner";

    $mail->send();
    echo json_encode(['success' => true]);
} catch (Exception $e) {
    echo json_encode(['success' => false, 'message' => 'Mailer error: ' . $mail->ErrorInfo]);
}
