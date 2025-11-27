import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:firebase_core/firebase_core.dart';
import '../../services/auth_service.dart';
import '../../providers/onboarding_provider.dart';
import '../../theme/app_theme.dart';
import 'auth_mode.dart';

class AuthScreen extends ConsumerStatefulWidget {
  final VoidCallback onLoginComplete;
  final VoidCallback onRegisterComplete;
  final VoidCallback? onBack;
  final AuthMode initialMode;
  final VoidCallback? onStartRegistration; // Called when user clicks "Register now"

  const AuthScreen({
    super.key,
    required this.onLoginComplete,
    required this.onRegisterComplete,
    this.onBack,
    this.initialMode = AuthMode.login,
    this.onStartRegistration,
  });

  @override
  ConsumerState<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends ConsumerState<AuthScreen> {
  late bool _isLoginMode; // Set from initialMode
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();
  final _nameController = TextEditingController();
  final _organizationController = TextEditingController();
  bool _isLoading = false;
  String? _errorMessage;
  bool _obscurePassword = true;
  bool _obscureConfirmPassword = true;
  bool _isFirebaseReady = false;

  @override
  void initState() {
    super.initState();
    _isLoginMode = widget.initialMode == AuthMode.login;
    _ensureFirebaseReady();
  }

  Future<void> _ensureFirebaseReady() async {
    // Check if Firebase is already initialized
    try {
      Firebase.app();
      // Firebase is already initialized
      if (mounted) {
        setState(() {
          _isFirebaseReady = true;
          _errorMessage = null;
        });
      }
      print('✅ Firebase already ready in AuthScreen');
      return;
    } catch (e) {
      // Firebase not initialized yet, wait for it
      print('⏳ Waiting for Firebase initialization...');
    }
    
    // Wait for Firebase to be initialized
    int retries = 0;
    const maxRetries = 50; // 5 seconds max wait
    
    while (retries < maxRetries) {
      try {
        // Try to access Firebase app to check if it's initialized
        Firebase.app();
        // If we get here, Firebase is initialized
        if (mounted) {
          setState(() {
            _isFirebaseReady = true;
            _errorMessage = null; // Clear any previous error
          });
        }
        print('✅ Firebase ready in AuthScreen');
        return;
      } catch (e) {
        // Firebase not initialized yet, wait and retry
        await Future.delayed(const Duration(milliseconds: 100));
        retries++;
      }
    }
    
    // If we get here, Firebase didn't initialize in time
    // But we'll still allow the user to try logging in (AuthService will handle initialization)
    if (mounted) {
      setState(() {
        _isFirebaseReady = true; // Allow login attempt anyway
        _errorMessage = null; // Clear error, let login handle it
      });
    }
    print('⚠️ Firebase initialization timeout, but allowing login attempt');
  }

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    _nameController.dispose();
    _organizationController.dispose();
    super.dispose();
  }

  Future<void> _handleLogin() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      print('🔵 Starting login process...');
      
      final validation = AuthService.validateLogin(
        _emailController.text,
        _passwordController.text,
      );

      if (!validation.valid) {
        setState(() {
          _errorMessage = validation.errors.values.first;
          _isLoading = false;
        });
        return;
      }

      print('✅ Validation passed, calling AuthService.login...');
      await AuthService.login(
        _emailController.text,
        _passwordController.text,
      );

      print('✅ Login successful, updating onboarding state...');
      // Mark camera as linked (user already has account, assume camera is set up)
      try {
        final onboardingNotifier = ref.read(onboardingProvider.notifier);
        await onboardingNotifier.setCameraLinked(true);
        await onboardingNotifier.completeOnboarding();
        print('✅ Onboarding state updated successfully');
      } catch (e) {
        // Don't block login if onboarding state update fails
        print('⚠️ Failed to update onboarding state: $e');
        print('⚠️ Continuing with login anyway...');
      }

      print('✅ Calling onLoginComplete...');
      widget.onLoginComplete();
    } catch (e) {
      print('❌ Login error: $e');
      print('❌ Error type: ${e.runtimeType}');
      setState(() {
        String errorMsg = e.toString().replaceAll('Exception: ', '');
        
        // Handle Firebase initialization errors
        if (errorMsg.contains('core/no-app') || errorMsg.contains('No Firebase App')) {
          errorMsg = 'Firebase is initializing, please wait and try again...';
        } else if (errorMsg.contains('Firebase not initialized') || errorMsg.contains('Firebase initialization failed')) {
          errorMsg = 'Firebase is initializing, please wait and try again...';
        } else if (errorMsg.contains('user-not-found')) {
          errorMsg = 'No account found with this email. Please check the email address or register first.';
        } else if (errorMsg.contains('wrong-password')) {
          errorMsg = 'Incorrect password. Please try again.';
        } else if (errorMsg.contains('network')) {
          errorMsg = 'Network error. Please check your network connection.';
        } else if (errorMsg.isEmpty) {
          errorMsg = 'Login failed. Please check the console logs for details.';
        }
        
        _errorMessage = errorMsg;
        _isLoading = false;
      });
    }
  }

  Future<void> _handleRegister() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      // Validate passwords match
      if (_passwordController.text != _confirmPasswordController.text) {
        setState(() {
          _errorMessage = 'Passwords do not match';
          _isLoading = false;
        });
        return;
      }

      final validation = AuthService.validateRegistration(
        _emailController.text,
        _passwordController.text,
        _nameController.text,
      );

      if (!validation.valid) {
        setState(() {
          _errorMessage = validation.errors.values.first;
          _isLoading = false;
        });
        return;
      }

      await AuthService.register(
        _emailController.text,
        _passwordController.text,
        _nameController.text,
        _organizationController.text.isEmpty ? null : _organizationController.text,
      );

      // Registration successful - will show welcome screens and guidelines
      // Check if widget is still mounted before calling callback
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
        print('✅ Registration successful, calling onRegisterComplete');
        widget.onRegisterComplete();
      }
    } catch (e) {
      setState(() {
        String errorMsg = e.toString().replaceAll('Exception: ', '');
        if (errorMsg.contains('permission-denied')) {
          errorMsg = 'Permission denied. Please check Firestore security rules.';
        } else if (errorMsg.contains('network')) {
          errorMsg = 'Network error. Please check your internet connection.';
        } else if (errorMsg.contains('email-already-in-use')) {
          errorMsg = 'This email is already registered. Please use the login function.';
        } else if (errorMsg.isEmpty) {
          errorMsg = 'Registration failed. Please check the browser console for details.';
        }
        _errorMessage = errorMsg;
        _isLoading = false;
      });
    }
  }

  void _switchToRegister() {
    // Directly switch to register mode in the same screen (no navigation to welcome screens)
    setState(() {
      _isLoginMode = false;
      _errorMessage = null;
      _emailController.clear();
      _passwordController.clear();
      _confirmPasswordController.clear();
      _nameController.clear();
      _organizationController.clear();
    });
    // Do NOT call onStartRegistration - we want to stay on the same screen
  }

  void _switchToLogin() {
    setState(() {
      _isLoginMode = true;
      _errorMessage = null;
      _emailController.clear();
      _passwordController.clear();
      _confirmPasswordController.clear();
      _nameController.clear();
      _organizationController.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    // Show loading state if Firebase is not ready yet
    if (!_isFirebaseReady) {
      return Scaffold(
        appBar: AppBar(
          leading: widget.onBack != null
              ? IconButton(
                  icon: const Icon(Icons.arrow_back),
                  onPressed: widget.onBack!,
                )
              : null,
          title: Text(_isLoginMode ? 'Login' : 'Register'),
        ),
        body: const Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              CircularProgressIndicator(),
              SizedBox(height: 16),
              Text(
                'Initializing Firebase...',
                style: TextStyle(color: AppTheme.mutedForeground),
              ),
            ],
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        leading: widget.onBack != null
            ? IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: widget.onBack!,
              )
            : null,
        title: Text(_isLoginMode ? 'Login' : 'Register'),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Title
            Text(
              _isLoginMode ? 'Welcome Back' : 'Create Account',
              style: const TextStyle(
                fontSize: 28,
                fontWeight: FontWeight.bold,
                color: AppTheme.foreground,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              _isLoginMode
                  ? 'Sign in to your CrowdSense account'
                  : 'Set up your account to get started',
              style: TextStyle(
                fontSize: 16,
                color: AppTheme.mutedForeground,
              ),
            ),
            const SizedBox(height: 32),
            
            // Error message
            if (_errorMessage != null)
              Container(
                padding: const EdgeInsets.all(12),
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                  color: AppTheme.destructive.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: AppTheme.destructive),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.error_outline, color: AppTheme.destructive),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _errorMessage!,
                        style: const TextStyle(color: AppTheme.destructive),
                      ),
                    ),
                  ],
                ),
              ),

            // Login Form
            if (_isLoginMode) ...[
              TextField(
                key: const Key('login_email_field'),
                controller: _emailController,
                keyboardType: TextInputType.emailAddress,
                autofillHints: const [AutofillHints.email],
                decoration: const InputDecoration(
                  labelText: 'Email',
                  hintText: 'Enter your email',
                  prefixIcon: Icon(Icons.email_outlined),
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                key: const Key('login_password_field'),
                controller: _passwordController,
                obscureText: _obscurePassword,
                autofillHints: const [AutofillHints.password],
                decoration: InputDecoration(
                  labelText: 'Password',
                  hintText: 'Enter your password',
                  prefixIcon: const Icon(Icons.lock_outlined),
                  suffixIcon: IconButton(
                    icon: Icon(
                      _obscurePassword ? Icons.visibility : Icons.visibility_off,
                      color: AppTheme.mutedForeground,
                    ),
                    onPressed: () {
                      setState(() {
                        _obscurePassword = !_obscurePassword;
                      });
                    },
                  ),
                ),
              ),
              const SizedBox(height: 32),
              SizedBox(
                width: double.infinity,
                height: 48,
                child: ElevatedButton(
                  onPressed: _isLoading ? null : _handleLogin,
                  child: _isLoading
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.login),
                            SizedBox(width: 8),
                            Text('Login'),
                          ],
                        ),
                ),
              ),
              const SizedBox(height: 24),
              // Register link
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    'Don\'t have an account? ',
                    style: TextStyle(
                      color: AppTheme.mutedForeground,
                    ),
                  ),
                  GestureDetector(
                    onTap: _switchToRegister,
                    child: const Text(
                      'Register now',
                      style: TextStyle(
                        color: AppTheme.primary,
                        fontWeight: FontWeight.bold,
                        decoration: TextDecoration.underline,
                      ),
                    ),
                  ),
                ],
              ),
            ] else ...[
              // Register Form
              TextField(
                key: const Key('register_name_field'),
                controller: _nameController,
                autofillHints: const [AutofillHints.name],
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(
                  labelText: 'Full Name',
                  hintText: 'Enter your name',
                  prefixIcon: Icon(Icons.person_outlined),
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                key: const Key('register_email_field'),
                controller: _emailController,
                keyboardType: TextInputType.emailAddress,
                autofillHints: const [AutofillHints.email],
                decoration: const InputDecoration(
                  labelText: 'Email',
                  hintText: 'Enter your email',
                  prefixIcon: Icon(Icons.email_outlined),
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                key: const Key('register_password_field'),
                controller: _passwordController,
                obscureText: _obscurePassword,
                autofillHints: const [AutofillHints.newPassword],
                decoration: InputDecoration(
                  labelText: 'Password',
                  hintText: 'Enter your password',
                  prefixIcon: const Icon(Icons.lock_outlined),
                  suffixIcon: IconButton(
                    icon: Icon(
                      _obscurePassword ? Icons.visibility : Icons.visibility_off,
                      color: AppTheme.mutedForeground,
                    ),
                    onPressed: () {
                      setState(() {
                        _obscurePassword = !_obscurePassword;
                      });
                    },
                  ),
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                key: const Key('register_confirm_password_field'),
                controller: _confirmPasswordController,
                obscureText: _obscureConfirmPassword,
                autofillHints: const [AutofillHints.newPassword],
                decoration: InputDecoration(
                  labelText: 'Confirm Password',
                  hintText: 'Confirm your password',
                  prefixIcon: const Icon(Icons.lock_outlined),
                  suffixIcon: IconButton(
                    icon: Icon(
                      _obscureConfirmPassword ? Icons.visibility : Icons.visibility_off,
                      color: AppTheme.mutedForeground,
                    ),
                    onPressed: () {
                      setState(() {
                        _obscureConfirmPassword = !_obscureConfirmPassword;
                      });
                    },
                  ),
                ),
              ),
              const SizedBox(height: 32),
              SizedBox(
                width: double.infinity,
                height: 48,
                child: ElevatedButton(
                  onPressed: _isLoading ? null : _handleRegister,
                  child: _isLoading
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.person_add),
                            SizedBox(width: 8),
                            Text('Register'),
                          ],
                        ),
                ),
              ),
              const SizedBox(height: 24),
              // Login link
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    'Already have an account? ',
                    style: TextStyle(
                      color: AppTheme.mutedForeground,
                    ),
                  ),
                  GestureDetector(
                    onTap: _switchToLogin,
                    child: const Text(
                      'Login now',
                      style: TextStyle(
                        color: AppTheme.primary,
                        fontWeight: FontWeight.bold,
                        decoration: TextDecoration.underline,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

