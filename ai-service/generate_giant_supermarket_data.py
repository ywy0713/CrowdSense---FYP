"""
Script to generate realistic 3-month analytics data for Giant Supermarket checkout zone.
This script generates data that reflects real supermarket patterns:
- Weekend peaks (Saturday/Sunday are busiest)
- Daily peak hours: 2-5 PM (afternoon shopping), 7-9 PM (evening shopping)
- Morning rush: 8-10 AM
- Late night/early morning: minimal traffic

Usage:
    python generate_giant_supermarket_data.py

The script will generate data for:
- Giant Setapak - Checkout 1 (busiest checkout, for demo purposes)

Data points are generated every 30 minutes to reduce insertion time while maintaining trend visibility.
"""

import json
import random
import time
from datetime import datetime, timedelta
from typing import List, Dict

# Firebase configuration
FIREBASE_DATABASE_URL = "https://crowdsense-caf2e-default-rtdb.asia-southeast1.firebasedatabase.app"

try:
    import firebase_admin
    from firebase_admin import credentials, db
    FIREBASE_ADMIN_AVAILABLE = True
except ImportError:
    FIREBASE_ADMIN_AVAILABLE = False
    print("⚠️  Firebase Admin SDK not installed. Install with: pip install firebase-admin")

try:
    import requests
    REQUESTS_AVAILABLE = True
except ImportError:
    REQUESTS_AVAILABLE = False
    print("⚠️  requests library not installed. Install with: pip install requests")

# Zone configuration (only one zone for demo purposes)
ZONES = [
    {
        'id': '-Og75IjQe1OAUWBeJwic',
        'name': 'Giant Setapak - Checkout 1',
        'busy_factor': 1.0,  # Busiest checkout
    },
]

# User ID
USER_ID = "wBV2mt1E2DhL0dWiLxKUNebvG4T2"

# Data generation parameters
MONTHS = 3  # 3 months of data
INTERVAL_MINUTES = 30  # Data point every 30 minutes (reduces total points while maintaining trends)


def generate_supermarket_pattern(
    start_time: datetime,
    days: int,
    interval_minutes: int,
    busy_factor: float
) -> List[Dict]:
    """
    Generate realistic supermarket checkout queue data.
    
    Patterns:
    - Weekend (Sat/Sun): 1.5x multiplier
    - Peak hours: 14:00-17:00 (afternoon), 19:00-21:00 (evening) - highest traffic
    - Morning rush: 08:00-10:00 - moderate traffic
    - Normal hours: 10:00-14:00, 17:00-19:00 - moderate traffic
    - Late night: 22:00-06:00 - minimal traffic (0-3 people)
    """
    data_points = []
    current_time = start_time
    end_time = start_time + timedelta(days=days)
    
    while current_time < end_time:
        hour = current_time.hour
        day_of_week = current_time.weekday()  # 0 = Monday, 6 = Sunday
        is_weekend = day_of_week >= 5  # Saturday or Sunday
        
        # Base count by time of day (for weekdays)
        if 14 <= hour <= 17:  # Afternoon peak (2-5 PM) - weekend shopping
            base_count = random.randint(8, 15) if is_weekend else random.randint(5, 10)
        elif 19 <= hour <= 21:  # Evening peak (7-9 PM) - after work shopping
            base_count = random.randint(10, 18) if is_weekend else random.randint(6, 12)
        elif 8 <= hour <= 10:  # Morning rush (8-10 AM) - early shoppers
            base_count = random.randint(4, 8) if is_weekend else random.randint(3, 6)
        elif 10 <= hour < 14:  # Mid-day (10 AM - 2 PM)
            base_count = random.randint(2, 6) if is_weekend else random.randint(1, 4)
        elif 17 <= hour < 19:  # Early evening (5-7 PM)
            base_count = random.randint(6, 12) if is_weekend else random.randint(4, 8)
        elif 22 <= hour or hour <= 6:  # Late night / early morning (10 PM - 6 AM)
            base_count = random.randint(0, 3)  # Minimal traffic
        else:  # Other hours
            base_count = random.randint(1, 5)
        
        # Apply busy factor (different checkouts have different traffic)
        count = int(base_count * busy_factor)
        
        # Add some natural variation (±2 people)
        count = count + random.randint(-2, 2)
        count = max(0, count)  # Ensure non-negative
        
        timestamp_ms = int(current_time.timestamp() * 1000)
        data_points.append({
            'timestamp': timestamp_ms,
            'count': count
        })
        
        current_time += timedelta(minutes=interval_minutes)
    
    return data_points


def insert_with_admin_sdk(zone_id: str, data_points: List[Dict], service_account_path: str = None):
    """Insert data using Firebase Admin SDK (recommended)"""
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
            # Try to use default credentials (serviceAccountKey.json in current directory)
            try:
                cred = credentials.Certificate('serviceAccountKey.json')
                firebase_admin.initialize_app(cred, {
                    'databaseURL': FIREBASE_DATABASE_URL
                })
            except Exception as e:
                print(f"❌ Error initializing Firebase Admin: {e}")
                print("💡 Please provide a service account JSON file:")
                print("   1. Go to Firebase Console → Project Settings → Service Accounts")
                print("   2. Click 'Generate new private key'")
                print("   3. Save as 'serviceAccountKey.json' in ai-service/ directory")
                print("   4. Or use --service-account path/to/file.json")
                raise
    
    # Get database reference
    ref = db.reference(f'analytics/{zone_id}/counts')
    
    # Insert data points
    print(f"📤 Inserting {len(data_points)} data points using Admin SDK...")
    inserted = 0
    for i, point in enumerate(data_points):
        ref.push().set(point)
        inserted += 1
        if (i + 1) % 100 == 0:
            print(f"   Progress: {inserted}/{len(data_points)}")
    
    print(f"✅ Zone {zone_id}: Inserted {inserted} data points!")
    return inserted


def insert_data_with_rest_api(zone_id: str, data_points: List[Dict], database_secret: str = None):
    """Insert data using Firebase REST API (requires database secret or open rules)"""
    if not REQUESTS_AVAILABLE:
        raise Exception("requests library not available")
    
    base_url = FIREBASE_DATABASE_URL.rstrip('/')
    path = f'/analytics/{zone_id}/counts.json'
    
    if database_secret:
        url = f"{base_url}{path}?auth={database_secret}"
    else:
        url = f"{base_url}{path}"
    
    print(f"📤 Inserting {len(data_points)} data points for zone {zone_id}...")
    
    inserted = 0
    failed = 0
    
    # Insert in batches to avoid overwhelming the API
    batch_size = 10
    for i in range(0, len(data_points), batch_size):
        batch = data_points[i:i+batch_size]
        
        for point in batch:
            try:
                response = requests.post(url, json=point, timeout=10)
                if response.status_code in [200, 201]:
                    inserted += 1
                else:
                    print(f"⚠️  Failed to insert: {response.status_code} - {response.text[:100]}")
                    failed += 1
            except Exception as e:
                print(f"⚠️  Error inserting point: {e}")
                failed += 1
            
            # Small delay to avoid rate limiting
            time.sleep(0.1)
        
        if (i + batch_size) % 100 == 0:
            print(f"   Progress: {inserted}/{len(data_points)} (failed: {failed})")
    
    print(f"✅ Zone {zone_id}: Inserted {inserted} data points (failed: {failed})")
    return inserted


def main():
    import argparse
    
    parser = argparse.ArgumentParser(description='Generate 6-month analytics data for Giant Supermarket zones')
    parser.add_argument('--method', type=str, choices=['admin', 'rest'], default='admin',
                       help='Method to use: admin (recommended, requires service account) or rest (requires database secret)')
    parser.add_argument('--service-account', type=str, default='serviceAccountKey.json',
                       help='Path to Firebase service account JSON file (default: serviceAccountKey.json)')
    parser.add_argument('--database-secret', type=str,
                       help='Database secret for REST API (only needed if using --method rest)')
    
    args = parser.parse_args()
    
    print("=" * 60)
    print("🏪 Giant Supermarket Analytics Data Generator")
    print("=" * 60)
    print()
    
    # Calculate date range (3 months ago to today)
    end_date = datetime.now()
    start_date = end_date - timedelta(days=MONTHS * 30)  # Approximate 3 months
    
    # Calculate estimated data points
    days = MONTHS * 30
    points_per_day = (24 * 60) // INTERVAL_MINUTES
    estimated_points = days * points_per_day
    
    print(f"📅 Date Range: {start_date.strftime('%Y-%m-%d')} to {end_date.strftime('%Y-%m-%d')}")
    print(f"📊 Interval: Every {INTERVAL_MINUTES} minutes")
    print(f"📈 Estimated data points: ~{estimated_points:,}")
    print(f"👤 User ID: {USER_ID}")
    print(f"📍 Zone: {ZONES[0]['name']}")
    print()
    
    total_inserted = 0
    total_failed = 0
    
    # Generate and insert data for each zone
    for zone in ZONES:
        print(f"\n{'=' * 60}")
        print(f"📍 Processing: {zone['name']}")
        print(f"   Zone ID: {zone['id']}")
        print(f"   Busy Factor: {zone['busy_factor']}")
        print(f"{'=' * 60}")
        
        # Generate data points
        data_points = generate_supermarket_pattern(
            start_date,
            MONTHS * 30,
            INTERVAL_MINUTES,
            zone['busy_factor']
        )
        
        print(f"✅ Generated {len(data_points)} data points")
        
        # Insert data
        try:
            if args.method == 'admin':
                if not FIREBASE_ADMIN_AVAILABLE:
                    print("❌ Firebase Admin SDK not available. Install with: pip install firebase-admin")
                    print("   Or use --method rest with --database-secret")
                    total_failed += len(data_points)
                    continue
                inserted = insert_with_admin_sdk(zone['id'], data_points, args.service_account)
                total_inserted += inserted
            else:  # rest method
                if not REQUESTS_AVAILABLE:
                    print("❌ requests library not available. Install with: pip install requests")
                    total_failed += len(data_points)
                    continue
                inserted = insert_data_with_rest_api(zone['id'], data_points, args.database_secret)
                total_inserted += inserted
        except Exception as e:
            print(f"❌ Error inserting data for {zone['name']}: {e}")
            total_failed += len(data_points)
    
    print()
    print("=" * 60)
    print("📊 Summary")
    print("=" * 60)
    print(f"✅ Total inserted: {total_inserted} data points")
    if total_failed > 0:
        print(f"❌ Total failed: {total_failed} data points")
    print()
    print("💡 Next steps:")
    print("   1. Open the CrowdSense app")
    print("   2. Navigate to Analytics page")
    print("   3. Select 'Giant Setapak - Checkout 1'")
    print("   4. Select date range (e.g., Last 30 Days or Last 3 Months)")
    print("   5. Generate Summary Report to see the analytics!")
    print()
    print("📝 Note: If you got permission errors, you need:")
    if args.method == 'admin':
        print("   - Firebase Admin SDK: pip install firebase-admin")
        print("   - Service account JSON file (serviceAccountKey.json)")
        print("   - Get it from: Firebase Console → Project Settings → Service Accounts")
    else:
        print("   - Database secret from Firebase Console")
        print("   - Or modify Firebase database rules to allow writes")
    print()


if __name__ == '__main__':
    main()

