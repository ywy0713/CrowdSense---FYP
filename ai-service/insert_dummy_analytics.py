"""
Script to insert dummy analytics data into Firebase Realtime Database
for CrowdSense analytics records.

Usage:
    python insert_dummy_analytics.py --zone-id <ZONE_ID> [options]

Options:
    --zone-id: Zone ID to insert data for (required)
    --days: Number of days of data to generate (default: 7)
    --interval-minutes: Interval between data points in minutes (default: 5)
    --min-count: Minimum people count (default: 0)
    --max-count: Maximum people count (default: 150)
    --method: Method to use - 'admin' or 'rest' (default: 'rest')
    --database-secret: Database secret for REST API (optional, if not provided will try to use Admin SDK)
"""

import argparse
import json
import random
import time
from datetime import datetime, timedelta
from typing import List, Dict

# Firebase configuration from Flutter app
FIREBASE_DATABASE_URL = "https://crowdsense-caf2e-default-rtdb.asia-southeast1.firebasedatabase.app"

try:
    import firebase_admin
    from firebase_admin import credentials, db
    FIREBASE_ADMIN_AVAILABLE = True
except ImportError:
    FIREBASE_ADMIN_AVAILABLE = False
    print("⚠️  Firebase Admin SDK not installed. Install with: pip install firebase-admin")
    print("   Will use REST API method instead.")

try:
    import requests
    REQUESTS_AVAILABLE = True
except ImportError:
    REQUESTS_AVAILABLE = False
    print("⚠️  requests library not installed. Install with: pip install requests")


def generate_realistic_count_pattern(start_time: datetime, days: int, interval_minutes: int, 
                                     min_count: int, max_count: int) -> List[Dict]:
    """
    Generate realistic people count data with daily patterns.
    Simulates higher counts during peak hours (morning 8-10, lunch 12-14, evening 17-19).
    """
    data_points = []
    current_time = start_time
    end_time = start_time + timedelta(days=days)
    
    while current_time < end_time:
        hour = current_time.hour
        day_of_week = current_time.weekday()  # 0 = Monday, 6 = Sunday
        
        # Base count varies by time of day
        if 8 <= hour <= 10:  # Morning peak
            base_count = random.randint(40, 80)
        elif 12 <= hour <= 14:  # Lunch peak
            base_count = random.randint(50, 90)
        elif 17 <= hour <= 19:  # Evening peak
            base_count = random.randint(60, 100)
        elif 22 <= hour or hour <= 6:  # Late night / early morning
            base_count = random.randint(0, 20)
        else:  # Normal hours
            base_count = random.randint(20, 60)
        
        # Weekends are typically busier
        if day_of_week >= 5:  # Saturday or Sunday
            base_count = int(base_count * 1.3)
        
        # Add some randomness
        count = base_count + random.randint(-15, 15)
        count = max(min_count, min(max_count, count))  # Clamp to range
        
        timestamp_ms = int(current_time.timestamp() * 1000)
        data_points.append({
            'timestamp': timestamp_ms,
            'count': count
        })
        
        current_time += timedelta(minutes=interval_minutes)
    
    return data_points


def insert_with_admin_sdk(zone_id: str, data_points: List[Dict], service_account_path: str = None):
    """Insert data using Firebase Admin SDK"""
    if not FIREBASE_ADMIN_AVAILABLE:
        raise Exception("Firebase Admin SDK not available")
    
    # Initialize Firebase Admin if not already initialized
    try:
        app = firebase_admin.get_app()
    except ValueError:
        if service_account_path:
            cred = credentials.Certificate(service_account_path)
            firebase_admin.initialize_app(cred, {
                'databaseURL': FIREBASE_DATABASE_URL
            })
        else:
            # Try to use default credentials
            try:
                firebase_admin.initialize_app(options={
                    'databaseURL': FIREBASE_DATABASE_URL
                })
            except Exception as e:
                print(f"❌ Error initializing Firebase Admin: {e}")
                print("💡 Please provide a service account JSON file using --service-account")
                raise
    
    # Get database reference
    ref = db.reference(f'analytics/{zone_id}/counts')
    
    # Insert data points
    print(f"📤 Inserting {len(data_points)} data points using Admin SDK...")
    inserted = 0
    for point in data_points:
        ref.push().set(point)
        inserted += 1
        if inserted % 50 == 0:
            print(f"   Progress: {inserted}/{len(data_points)}")
    
    print(f"✅ Successfully inserted {inserted} data points!")
    return inserted


def insert_with_rest_api(zone_id: str, data_points: List[Dict], database_secret: str = None):
    """Insert data using Firebase REST API"""
    if not REQUESTS_AVAILABLE:
        raise Exception("requests library not available")
    
    # Build the URL
    base_url = FIREBASE_DATABASE_URL.rstrip('/')
    path = f'/analytics/{zone_id}/counts.json'
    
    if database_secret:
        url = f"{base_url}{path}?auth={database_secret}"
    else:
        # Try without auth (will work if database rules allow unauthenticated writes)
        url = f"{base_url}{path}"
    
    print(f"📤 Inserting {len(data_points)} data points using REST API...")
    print(f"   URL: {base_url}/analytics/{zone_id}/counts")
    
    inserted = 0
    failed = 0
    
    # Insert in batches to avoid overwhelming the API
    batch_size = 10
    for i in range(0, len(data_points), batch_size):
        batch = data_points[i:i+batch_size]
        
        for point in batch:
            try:
                # Use POST to create a new entry with auto-generated key
                response = requests.post(url, json=point, timeout=10)
                if response.status_code in [200, 201]:
                    inserted += 1
                else:
                    print(f"⚠️  Failed to insert point at {point['timestamp']}: {response.status_code} - {response.text}")
                    failed += 1
            except Exception as e:
                print(f"⚠️  Error inserting point: {e}")
                failed += 1
            
            # Small delay to avoid rate limiting
            time.sleep(0.1)
        
        if (i + batch_size) % 50 == 0:
            print(f"   Progress: {inserted}/{len(data_points)} (failed: {failed})")
    
    print(f"✅ Successfully inserted {inserted} data points! (failed: {failed})")
    return inserted


def main():
    parser = argparse.ArgumentParser(description='Insert dummy analytics data into Firebase')
    parser.add_argument('--zone-id', type=str, required=True, help='Zone ID to insert data for')
    parser.add_argument('--days', type=int, default=7, help='Number of days of data to generate (default: 7)')
    parser.add_argument('--interval-minutes', type=int, default=5, help='Interval between data points in minutes (default: 5)')
    parser.add_argument('--min-count', type=int, default=0, help='Minimum people count (default: 0)')
    parser.add_argument('--max-count', type=int, default=150, help='Maximum people count (default: 150)')
    parser.add_argument('--method', type=str, choices=['admin', 'rest'], default='rest', 
                       help='Method to use: admin (requires service account) or rest (default: rest)')
    parser.add_argument('--database-secret', type=str, help='Database secret for REST API (optional)')
    parser.add_argument('--service-account', type=str, help='Path to Firebase service account JSON file (for admin method)')
    parser.add_argument('--start-date', type=str, help='Start date in YYYY-MM-DD format (default: today - days)')
    
    args = parser.parse_args()
    
    # Calculate start date
    if args.start_date:
        start_date = datetime.strptime(args.start_date, '%Y-%m-%d')
    else:
        start_date = datetime.now() - timedelta(days=args.days)
    
    # Generate data points
    print(f"📊 Generating dummy analytics data...")
    print(f"   Zone ID: {args.zone_id}")
    print(f"   Period: {start_date.strftime('%Y-%m-%d')} to {(start_date + timedelta(days=args.days)).strftime('%Y-%m-%d')}")
    print(f"   Interval: {args.interval_minutes} minutes")
    print(f"   Count range: {args.min_count} - {args.max_count}")
    
    data_points = generate_realistic_count_pattern(
        start_date, 
        args.days, 
        args.interval_minutes,
        args.min_count,
        args.max_count
    )
    
    print(f"✅ Generated {len(data_points)} data points")
    
    # Insert data
    try:
        if args.method == 'admin':
            if not FIREBASE_ADMIN_AVAILABLE:
                print("❌ Firebase Admin SDK not available. Switching to REST API method...")
                args.method = 'rest'
            else:
                insert_with_admin_sdk(args.zone_id, data_points, args.service_account)
                return
        
        if args.method == 'rest':
            if not REQUESTS_AVAILABLE:
                print("❌ requests library not available. Please install it: pip install requests")
                return
            
            insert_with_rest_api(args.zone_id, data_points, args.database_secret)
    
    except Exception as e:
        print(f"❌ Error: {e}")
        print("\n💡 Troubleshooting:")
        print("   1. Make sure you have the correct zone ID")
        print("   2. Check Firebase database rules allow writes")
        print("   3. For REST API: You may need a database secret (get from Firebase Console > Project Settings > Service Accounts)")
        print("   4. For Admin SDK: Provide --service-account path to your service account JSON file")
        return


if __name__ == '__main__':
    main()



