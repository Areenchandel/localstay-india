import json
import boto3

dynamodb = boto3.resource('dynamodb', region_name='ap-south-1')
table = dynamodb.Table('localstay-bookings')

def lambda_handler(event, context):
    headers = {
        'Access-Control-Allow-Origin': '*',
        'Access-Control-Allow-Headers': 'Content-Type',
        'Access-Control-Allow-Methods': 'GET,OPTIONS'
    }

    try:
        result = table.scan()
        items = result.get('Items', [])

        # Sort by timestamp descending
        items.sort(key=lambda x: x.get('timestamp', ''), reverse=True)

        # Summary stats
        total_bookings = len(items)
        total_revenue = sum(int(i.get('total', 0)) for i in items)

        city_counts = {}
        for item in items:
            city = item.get('city', 'Unknown')
            city_counts[city] = city_counts.get(city, 0) + 1

        top_city = max(city_counts, key=city_counts.get) if city_counts else 'N/A'

        return {
            'statusCode': 200,
            'headers': headers,
            'body': json.dumps({
                'bookings': items,
                'stats': {
                    'total_bookings': total_bookings,
                    'total_revenue': total_revenue,
                    'top_city': top_city,
                    'city_breakdown': city_counts
                }
            })
        }

    except Exception as e:
        return {
            'statusCode': 500,
            'headers': headers,
            'body': json.dumps({ 'error': str(e) })
        }
