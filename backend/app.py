from flask import Flask, request, jsonify
from flask_cors import CORS
import boto3
import uuid
from datetime import datetime

app = Flask(__name__)
CORS(app)

dynamodb = boto3.resource('dynamodb', region_name='ap-south-1')
table = dynamodb.Table('localstay-bookings')

@app.route('/api/booking', methods=['POST'])
def create_booking():
    data = request.json
    booking_id = 'LS-' + str(uuid.uuid4())[:8].upper()
    item = {
        'booking_id':      booking_id,
        'name':            data.get('name', ''),
        'email':           data.get('email', ''),
        'phone':           data.get('phone', ''),
        'property':        data.get('property', ''),
        'city':            data.get('city', ''),
        'host':            data.get('host', ''),
        'checkin':         data.get('checkin', ''),
        'checkout':        data.get('checkout', ''),
        'guests':          str(data.get('guests', 1)),
        'nights':          str(data.get('nights', 1)),
        'price_per_night': str(data.get('price_per_night', 0)),
        'total':           str(data.get('total', 0)),
        'payment':         data.get('payment', 'UPI'),
        'timestamp':       datetime.utcnow().isoformat(),
        'status':          'confirmed'
    }
    table.put_item(Item=item)
    return jsonify({ 'success': True, 'booking_id': booking_id })

@app.route('/api/bookings', methods=['GET'])
def get_bookings():
    result = table.scan()
    items = result.get('Items', [])
    total_revenue = sum(int(i.get('total', 0)) for i in items)
    return jsonify({
        'bookings': items,
        'stats': {
            'total_bookings': len(items),
            'total_revenue': total_revenue
        }
    })

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=5000)
