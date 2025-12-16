"""
Script to generate realistic 3-month analytics data for TAR UMT Bus Stop.
This script generates data that reflects real university bus stop patterns:
- Weekday morning rush (7-9 AM): Students going to campus
- Weekday afternoon rush (3-6 PM): Students leaving campus
- Weekend: Minimal traffic (fewer classes)
- Exam weeks: Higher traffic during exam periods
- Semester breaks: Lower traffic

Usage:
    python generate_tarumt_bus_stop_data.py

Data points are generated every 1 hour to reduce insertion time while maintaining trend visibility.
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

# Zone configuration
ZONE_ID = "-OgDjXYA-TCpe5o4tSez"
ZONE_NAME = "TARUMT - Bus Stop A"
USER_ID = "EHnGIPJ25jWyw2pumTpy6gBIEff1"

# Data generation parameters
MONTHS = 3  # 3 months of data
INTERVAL_MINUTES = 60  # Data point every 1 hour (reduces total points while maintaining trends)


def generate_bus_stop_pattern(
    start_time: datetime,
    days: int,
    interval_minutes: int
) -> List[Dict]:
    """
    Generate realistic university bus stop queue data.
    
    Patterns:
    - Weekday morning rush (7-9 AM): High traffic (students going to campus)
    - Weekday afternoon rush (3-6 PM): Highest traffic (students leaving campus)
    - Mid-day (10 AM - 2 PM): Moderate traffic (between classes)
    - Evening (7-9 PM): Moderate traffic (late classes ending)
    - Late night (10 PM - 6 AM): Minimal traffic (0-5 people)
    - Weekend: Generally lower traffic, but some activity on Saturday morning
    - Exam weeks: Slightly higher traffic during exam periods
    """
    data_points = []
    current_time = start_time
    end_time = start_time + timedelta(days=days)
    
    # Simulate exam weeks (weeks 6, 12, 18 of the 3-month period)
    exam_weeks = [6, 12, 18]
    
    while current_time < end_time:
        hour = current_time.hour
        day_of_week = current_time.weekday()  # 0 = Monday, 6 = Sunday
        is_weekend = day_of_week >= 5  # Saturday or Sunday
        is_saturday = day_of_week == 5
        
        # Calculate which week we're in (from start_time)
        days_elapsed = (current_time - start_time).days
        current_week = (days_elapsed // 7) + 1
        is_exam_week = current_week in exam_weeks
        
        # Base count by time of day (for weekdays)
        if is_weekend:
            # Weekend: Much lower traffic
            if is_saturday and 8 <= hour <= 10:  # Saturday morning (some students still come)
                base_count = random.randint(5, 15)
            elif 7 <= hour <= 9:  # Weekend morning
                base_count = random.randint(2, 8)
            elif 15 <= hour <= 17:  # Weekend afternoon
                base_count = random.randint(3, 10)
            else:
                base_count = random.randint(0, 5)
        else:
            # Weekday patterns
            if 7 <= hour <= 9:  # Morning rush (7-9 AM) - students going to campus
                base_count = random.randint(20, 40)  # High traffic
            elif 15 <= hour <= 18:  # Afternoon rush (3-6 PM) - students leaving campus
                base_count = random.randint(30, 55)  # Highest traffic (peak hours)
            elif 10 <= hour < 15:  # Mid-day (10 AM - 2 PM) - between classes
                base_count = random.randint(8, 20)
            elif 19 <= hour <= 21:  # Evening (7-9 PM) - late classes ending
                base_count = random.randint(10, 25)
            elif 22 <= hour or hour <= 6:  # Late night / early morning (10 PM - 6 AM)
                base_count = random.randint(0, 5)  # Minimal traffic
            else:  # Other hours
                base_count = random.randint(3, 12)
        
        # Apply exam week multiplier (slightly higher traffic during exams)
        if is_exam_week:
            base_count = int(base_count * 1.2)  # 20% increase during exam weeks
        
        # Add some natural variation (±3 people)
        count = base_count + random.randint(-3, 3)
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
    
    parser = argparse.ArgumentParser(description='Generate 3-month analytics data for TAR UMT Bus Stop')
    parser.add_argument('--method', type=str, choices=['admin', 'rest'], default='admin',
                       help='Method to use: admin (recommended, requires service account) or rest (requires database secret)')
    parser.add_argument('--service-account', type=str, default='serviceAccountKey.json',
                       help='Path to Firebase service account JSON file (default: serviceAccountKey.json)')
    parser.add_argument('--database-secret', type=str,
                       help='Database secret for REST API (only needed if using --method rest)')
    
    args = parser.parse_args()
    
    print("=" * 60)
    print("🚌 TAR UMT Bus Stop Analytics Data Generator")
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
    print(f"📊 Interval: Every {INTERVAL_MINUTES} minutes (1 hour)")
    print(f"📈 Estimated data points: ~{estimated_points:,}")
    print(f"👤 User ID: {USER_ID}")
    print(f"📍 Zone: {ZONE_NAME}")
    print(f"🆔 Zone ID: {ZONE_ID}")
    print()
    
    # Generate data points
    print(f"🔄 Generating data points...")
    data_points = generate_bus_stop_pattern(
        start_date,
        MONTHS * 30,
        INTERVAL_MINUTES
    )
    
    print(f"✅ Generated {len(data_points)} data points")
    print()
    
    # Show sample statistics
    counts = [p['count'] for p in data_points]
    print(f"📊 Data Statistics:")
    print(f"   Min count: {min(counts)}")
    print(f"   Max count: {max(counts)}")
    print(f"   Average count: {sum(counts) / len(counts):.1f}")
    print()
    
    # Insert data
    try:
        if args.method == 'admin':
            if not FIREBASE_ADMIN_AVAILABLE:
                print("❌ Firebase Admin SDK not available. Install with: pip install firebase-admin")
                print("   Or use --method rest with --database-secret")
                return
            inserted = insert_with_admin_sdk(ZONE_ID, data_points, args.service_account)
        else:  # rest method
            if not REQUESTS_AVAILABLE:
                print("❌ requests library not available. Install with: pip install requests")
                return
            inserted = insert_data_with_rest_api(ZONE_ID, data_points, args.database_secret)
        
        print()
        print("=" * 60)
        print("📊 Summary")
        print("=" * 60)
        print(f"✅ Total inserted: {inserted} data points")
        print()
        print("💡 Next steps:")
        print("   1. Open the CrowdSense app")
        print("   2. Navigate to Analytics page")
        print(f"   3. Select '{ZONE_NAME}'")
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
    except Exception as e:
        print(f"❌ Error inserting data: {e}")
        import traceback
        traceback.print_exc()


if __name__ == '__main__':
    main()

