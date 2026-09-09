// send-handover-email
// Called from admin.html when the IT admin clicks "Email to employee".
// Reads SMTP settings from the `settings` table and sends the handover
// email (with the PDF attached) using SMTP.

import { SMTPClient } from "https://deno.land/x/denomailer@1.6.0/mod.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    const { to, employeeName, subject, html, pdfBase64, pdfFilename } = await req.json();
    if (!to) throw new Error("Missing recipient email address.");

    const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
    const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
    const supabase = createClient(supabaseUrl, serviceKey);

    const { data: settings, error } = await supabase
      .from("settings")
      .select("*")
      .eq("id", 1)
      .single();

    if (error || !settings || !settings.smtp_host || !settings.smtp_username) {
      throw new Error("SMTP is not configured yet. Go to Admin → Settings and save your SMTP details first.");
    }

    const port = Number(settings.smtp_port || 587);

    const client = new SMTPClient({
      connection: {
        hostname: settings.smtp_host,
        port,
        tls: port === 465,
        auth: {
          username: settings.smtp_username,
          password: settings.smtp_password,
        },
      },
    });

    const attachments = [];
    if (pdfBase64) {
      attachments.push({
        filename: pdfFilename || "Handover.pdf",
        content: pdfBase64,
        encoding: "base64",
      });
    }

    await client.send({
      from: `${settings.smtp_from_name || "DNCC IT Department"} <${settings.smtp_from_email || settings.smtp_username}>`,
      to,
      subject: subject || "Your Mobile Device Handover Confirmation — DNCC IT",
      html: html || `<p>Hi ${employeeName || ""},</p><p>This confirms your submitted mobile device handover details with DNCC IT Department. Your handover PDF is attached for your records.</p>`,
      attachments,
    });

    await client.close();

    return new Response(JSON.stringify({ ok: true }), {
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  } catch (err) {
    return new Response(JSON.stringify({ ok: false, error: String(err && err.message ? err.message : err) }), {
      status: 400,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }
});
