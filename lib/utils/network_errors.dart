import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart'
    show AuthRetryableFetchException, FunctionsFetchException;

import '../models/exceptions.dart';

/// What a send says when the network is the problem.
///
/// Offline, a send used to report "Failed to send: RepositoryException: Failed
/// to insert: ClientException: Failed host lookup..." - true, and useless to
/// anyone holding a phone in airplane mode.
const noInternetMessage =
    'No internet connection. Check your connection and try again.';

/// What opening a clip's file says when it was never downloaded here and the
/// device is offline. The clip itself shows - offline history keeps the list -
/// but its file lives in storage, so there is nothing to open until the
/// connection is back.
const offlineFileMessage =
    "No internet connection. This file hasn't been downloaded to this device "
    'yet.';

/// Whether [error] means the server could not be reached, rather than that it
/// refused the request.
///
/// Offline, the Supabase client throws http's [http.ClientException] wrapping
/// the socket error, not a [SocketException] itself; the auth client throws
/// [AuthRetryableFetchException]; the functions client wraps it in
/// [FunctionsFetchException]; and a request that outlives its deadline
/// (see TimeoutHttpClient) throws [TimeoutException].
bool isNetworkError(Object error) =>
    error is NetworkException ||
    error is SocketException ||
    error is TlsException ||
    error is http.ClientException ||
    error is TimeoutException ||
    error is AuthRetryableFetchException ||
    error is FunctionsFetchException;

/// [noInternetMessage] for a network failure, otherwise [fallback].
String sendFailureMessage(Object error, String fallback) =>
    isNetworkError(error) ? noInternetMessage : fallback;
