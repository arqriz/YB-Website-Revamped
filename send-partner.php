<?php
header('Content-Type: application/json');

// Only accept POST
if ($_SERVER['REQUEST_METHOD'] !== 'POST') {
    echo json_encode(['success' => false, 'message' => 'Method not allowed.']);
    exit;
}

// Sanitise inputs
function clean($val) {
    return htmlspecialchars(strip_tags(trim($val ?? '')));
}

$name         = clean($_POST['name'] ?? '');
$email        = clean($_POST['email'] ?? '');
$organisation = clean($_POST['organisation'] ?? '');
$phone        = clean($_POST['phone'] ?? '');
$message      = clean($_POST['message'] ?? '');

// Basic validation
if (empty($name) || empty($email) || empty($message)) {
    echo json_encode(['success' => false, 'message' => 'Required fields missing.']);
    exit;
}

if (!filter_var($email, FILTER_VALIDATE_EMAIL)) {
    echo json_encode(['success' => false, 'message' => 'Invalid email address.']);
    exit;
}

// Email configuration
$to      = 'hazel_koh@yellowbin.com.my';
$subject = 'New Partnership Enquiry — ' . $name . ($organisation ? ' (' . $organisation . ')' : '');

$body  = "New partnership enquiry from the Yellow Bin website.\n\n";
$body .= "Name:         " . $name . "\n";
$body .= "Email:        " . $email . "\n";
$body .= "Organisation: " . ($organisation ?: 'Not provided') . "\n";
$body .= "Phone:        " . ($phone ?: 'Not provided') . "\n\n";
$body .= "Message:\n" . $message . "\n\n";
$body .= "---\nSent from yellowbin.com.my/partner";

$headers  = "From: noreply@yellowbin.com.my\r\n";
$headers .= "Reply-To: " . $email . "\r\n";
$headers .= "X-Mailer: PHP/" . phpversion();

$sent = mail($to, $subject, $body, $headers);

if ($sent) {
    echo json_encode(['success' => true]);
} else {
    echo json_encode(['success' => false, 'message' => 'Mail server error.']);
}
