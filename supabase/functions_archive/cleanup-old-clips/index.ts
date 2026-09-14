import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";
const supabaseUrl = Deno.env.get("SUPABASE_URL") || "";
const supabaseServiceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || "";
const functionSecret = Deno.env.get("FUNCTION_SECRET") || "";
if (!supabaseUrl || !supabaseServiceKey || !functionSecret) {
  throw new Error("Missing required environment variables");
}
const supabase = createClient(supabaseUrl, supabaseServiceKey);
Deno.serve(async (req)=>{
  try {
    // IMPORTANT: Verify the Bearer token matches our function secret
    // This prevents unauthorized calls from the internet
    const authHeader = req.headers.get("authorization");
    if (!authHeader || !authHeader.startsWith("Bearer ")) {
      console.error("Missing or invalid Authorization header");
      return new Response(JSON.stringify({
        error: "Unauthorized: Missing Authorization header"
      }), {
        status: 401,
        headers: {
          "Content-Type": "application/json"
        }
      });
    }
    const token = authHeader.substring(7); // Remove "Bearer " prefix
    if (token !== functionSecret) {
      console.error("Invalid authentication token");
      return new Response(JSON.stringify({
        error: "Unauthorized: Invalid token"
      }), {
        status: 401,
        headers: {
          "Content-Type": "application/json"
        }
      });
    }
    console.log("[cleanup-old-clips] Starting deep cleanup of old clipboard items...");
    // Call the deep cleanup function with service role (admin) privileges
    const { error } = await supabase.rpc("cleanup_old_clipboard_items_deep", {}, {
      headers: {
        "x-client-info": "supabase-js-edge-function/v1"
      }
    });
    if (error) {
      console.error("[cleanup-old-clips] Cleanup error:", error);
      return new Response(JSON.stringify({
        success: false,
        error: error.message,
        code: error.code
      }), {
        status: 500,
        headers: {
          "Content-Type": "application/json"
        }
      });
    }
    console.log("[cleanup-old-clips] Deep cleanup completed successfully");
    return new Response(JSON.stringify({
      success: true,
      message: "Successfully deleted clipboard items older than 30 days",
      timestamp: new Date().toISOString()
    }), {
      status: 200,
      headers: {
        "Content-Type": "application/json"
      }
    });
  } catch (error) {
    console.error("[cleanup-old-clips] Unexpected error:", error);
    return new Response(JSON.stringify({
      success: false,
      error: String(error)
    }), {
      status: 500,
      headers: {
        "Content-Type": "application/json"
      }
    });
  }
});
