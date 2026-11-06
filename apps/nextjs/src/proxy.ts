import type { NextRequest } from "next/server";
import { NextResponse } from "next/server";

import { getDefaultLocaleForProxyAsync, getOnboardingStepForProxyAsync } from "@homarr/db/proxy-reader";
import { localeCookieKey } from "@homarr/definitions/cookie";
import type { SupportedLanguage } from "@homarr/translation/languages";
import { supportedLanguages } from "@homarr/translation/languages";
import { createI18nMiddleware } from "@homarr/translation/middleware";

let isOnboardingFinished = false;
let onboardingStepPromise: Promise<string> | null = null;
let defaultLocalePromise: Promise<string> | null = null;

const getOnboardingStepDedupedAsync = () => {
  onboardingStepPromise ??= getOnboardingStepForProxyAsync().then(
    (step) => {
      onboardingStepPromise = null;
      return step;
    },
    (error: unknown) => {
      onboardingStepPromise = null;
      throw error;
    },
  );
  return onboardingStepPromise;
};

const getDefaultLocaleDedupedAsync = () => {
  defaultLocalePromise ??= getDefaultLocaleForProxyAsync().then(
    (locale) => {
      defaultLocalePromise = null;
      return locale;
    },
    (error: unknown) => {
      defaultLocalePromise = null;
      throw error;
    },
  );
  return defaultLocalePromise;
};

export async function proxy(request: NextRequest) {
  // Redirect to onboarding if it's not finished yet
  const pathname = request.nextUrl.pathname;
  const segments = pathname.split("/").filter(Boolean);
  const routeSegments = supportedLanguages.includes(segments[0] as SupportedLanguage) ? segments.slice(1) : segments;
  const isOnboardingAccessRoute =
    (routeSegments.length === 1 && routeSegments[0] === "init") ||
    (routeSegments.length === 2 && routeSegments[0] === "auth" && routeSegments[1] === "login");

  if (!isOnboardingFinished && !isOnboardingAccessRoute) {
    const currentOnboardingStep = await getOnboardingStepDedupedAsync();
    if (currentOnboardingStep !== "finish") {
      const host = request.headers.get("host") ?? request.nextUrl.host;
      const protocol =
        request.headers.get("x-forwarded-proto")?.split(",")[0]?.trim() ??
        request.nextUrl.protocol.replace(":", "");
      return NextResponse.redirect(new URL("/init", `${protocol}://${host}`));
    }

    isOnboardingFinished = true;
  }

  // Only run this if the user has not already configured their language
  const currentLocale = request.cookies.get(localeCookieKey)?.value;
  let defaultLocale: SupportedLanguage = "en";
  if (!currentLocale || !supportedLanguages.includes(currentLocale as SupportedLanguage)) {
    const configuredLocale = await getDefaultLocaleDedupedAsync();
    if (supportedLanguages.includes(configuredLocale as SupportedLanguage)) {
      defaultLocale = configuredLocale as SupportedLanguage;
    }
  }

  // Onboarding access routes must stay reachable without an external redirect
  // loop when the app is accessed through 127.0.0.1. See proxy handling above.
  if (!isOnboardingFinished && isOnboardingAccessRoute) {
    const host = request.headers.get("host") ?? request.nextUrl.host;
    const protocol =
      request.headers.get("x-forwarded-proto")?.split(",")[0]?.trim() ??
      request.nextUrl.protocol.replace(":", "");
    const headers = new Headers(request.headers);
    headers.set("accept-language", "");
    headers.set("X-NEXT-INTL-LOCALE", defaultLocale);

    const response = NextResponse.rewrite(
      new URL(`/${defaultLocale}/${routeSegments.join("/")}${request.nextUrl.search}`, `${protocol}://${host}`),
      { request: { headers } },
    );
    response.cookies.set(localeCookieKey, defaultLocale, {
      maxAge: 60 * 60 * 24 * 365,
      path: "/",
    });
    return response;
  }

  // We don't want to fallback to accept-language header so we clear it
  request.headers.set("accept-language", "");

  const next = createI18nMiddleware(defaultLocale);
  return next(request);
}

export const config = {
  matcher: ["/((?!api|static|.*\\..*|_next|favicon.ico|robots.txt).*)"],
};
