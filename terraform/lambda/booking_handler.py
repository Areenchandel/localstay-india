import json
import boto3
import uuid
from datetime import datetime

dynamodb = boto3.resource('dynamodb', region_name='ap-south-1')
sns = boto3.client('sns', region_name='ap-south-1')
table = dynamodb.Table('localstay-bookings')

# Replace with your SNS topic ARN after Terraform apply
SNS_TOPIC_ARN = 'arn:aws:sns:ap-south-1:YOUR_ACCOUNT_ID:localstay-booking-alerts'

def lambda_handler(event, context):
    headers = {
        'Access-Control-Allow-Origin': '*',
        'Access-Control-Allow-Headers': 'Content-Type',
        'Access-Control-Allow-Methods': 'POST,OPTIONS'
    }

    # Handle CORS preflight
    if event.get('httpMethod') == 'OPTIONS':
        return { 'statusCode': 200, 'headers': headers, 'body': '' }

    try:
        body = json.loads(event.get('body', '{}'))

        booking_id = 'LS-' + str(uuid.uuid4())[:8].upper()
        timestamp = datetime.utcnow().isoformat()

        item = {
            'booking_id':      booking_id,
            'name':            body.get('name', ''),
            'email':           body.get('email', ''),
            'phone':           body.get('phone', ''),
            'property':        body.get('property', ''),
            'city':            body.get('city', ''),
            'host':            body.get('host', ''),
            'checkin':         body.get('checkin', ''),
            'checkout':        body.get('checkout', ''),
            'guests':          str(body.get('guests', 1)),
            'nights':          str(body.get('nights', 1)),
            'price_per_night': str(body.get('price_per_night', 0)),
            'total':           str(body.get('total', 0)),
            'payment':         body.get('payment', 'UPI'),
            'timestamp':       timestamp,
            'status':          'confirmed'
        }

        # Save to DynamoDB
        table.put_item(Item=item)

        # Send SNS email notification
        message = f"""
🎉 New LocalStay Booking!

Booking ID : {booking_id}
Guest Name : {item['name']}
Email      : {item['email']}
Phone      : {item['phone']}

Property   : {item['property']}
City       : {item['city']}
Host       : {item['host']}

Check-in   : {item['checkin']}
Check-out  : {item['checkout']}
Nights     : {item['nights']}
Guests     : {item['guests']}

Total      : ₹{item['total']}
Payment    : {item['payment']}
Booked at  : {timestamp} UTC

---
LocalStay India · Authentic Homestays
        """.strip()

        try:
            sns.publish(
                TopicArn=SNS_TOPIC_ARN,
                Subject=f'New Booking: {item["property"]} [{booking_id}]',
                Message=message
            )
        except Exception as sns_err:
            print(f'SNS error (non-fatal): {sns_err}')

        return {
            'statusCode': 200,
            'headers': headers,
            'body': json.dumps({
                'success': True,
                'booking_id': booking_id,
                'message': 'Booking confirmed! Your host will contact you within 2 hours.'
            })
        }

    except Exception as e:
        print(f'Error: {e}')
        return {
            'statusCode': 500,
            'headers': headers,
            'body': json.dumps({ 'success': False, 'error': str(e) })
        }
