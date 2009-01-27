static inline INT ADD_PREFIX(IEEECOMPARE) (REAL, REAL, const char*) occam_unused;
static inline INT ADD_PREFIX(IEEECOMPARE) (REAL X, REAL Y, const char* pos) {
	if (isunordered(X,Y)) {
		return 2;
	} else if (isgreater(X,Y)) {
		return 1;
	} else if (isless(X,Y)) {
		return -1;
	} else {
		return 0;
	}
}
static inline BOOL SPLICE_SIZE(occam_IEEE,OP) (REAL, INT, INT, REAL, REAL*, const char*) occam_unused;
static inline BOOL SPLICE_SIZE(occam_IEEE,OP) (REAL X, INT Rm, INT Op, REAL Y, REAL* result1, const char* pos) {
	return 0;
}
static inline BOOL SPLICE_SIZE(occam_IEEE,REM) (REAL, REAL, REAL*, const char*) occam_unused;
static inline BOOL SPLICE_SIZE(occam_IEEE,REM) (REAL X, REAL Y, REAL* result1, const char* pos) {
	return 0;
}
static inline BOOL SPLICE_SIZE(occam_REAL,EQ) (REAL, REAL, const char*) occam_unused;
static inline BOOL SPLICE_SIZE(occam_REAL,EQ) (REAL X, REAL Y, const char* pos) {
	return 0;
}
static inline BOOL SPLICE_SIZE(occam_REAL,GT) (REAL, REAL, const char*) occam_unused;
static inline BOOL SPLICE_SIZE(occam_REAL,GT) (REAL X, REAL Y, const char* pos) {
	return isgreater(X,Y);
}
static inline REAL SPLICE_SIZE(occam_REAL,OP) (REAL, INT, REAL, const char*) occam_unused;
static inline REAL SPLICE_SIZE(occam_REAL,OP) (REAL X, INT Op, REAL Y, const char* pos) {
	switch (Op) {
		case 0: return X+Y;
		case 1: return X-Y;
		case 2: return X*Y;
		case 3: return X/Y;
		default: return 0;
	}
}
static inline REAL SPLICE_SIZE(occam_REAL,REM) (REAL, REAL, const char*) occam_unused;
static inline REAL SPLICE_SIZE(occam_REAL,REM) (REAL X, REAL Y, const char* pos) {
	return 0;
}
#if SPLICE_SIZE(4,1) == 4321
static inline BOOL occam_ARGUMENT_REDUCE (float, float, float, int32_t*, float*, const char*) occam_unused;
static inline BOOL occam_ARGUMENT_REDUCE (float X, float Y, float Y_err, int32_t* result1, float* result2, const char* pos) {
	const INT maxexpdiff = 20;
#else
static inline BOOL occam_DARGUMENT_REDUCE (double, double, double, int32_t*, double*, const char*) occam_unused;
static inline BOOL occam_DARGUMENT_REDUCE (double X, double Y, double Y_err, int32_t* result1, double* result2, const char* pos) {
	const INT maxexpdiff = 30;
#endif
	int EX;
	int EY;
	F(frexp)(X,&EX);
	F(frexp)(Y,&EY);
	if (EX > EY + maxexpdiff) {
		*result2 = F(remainder)(X,Y);
		return false;
	} else {
		int R;
		*result2 = F(remquo)(X,Y,&R);
		*result1 = R;
		return true;
	}
}

static inline REAL ADD_PREFIX(ABS) (REAL, const char*) occam_unused;
static inline REAL ADD_PREFIX(ABS) (REAL X, const char* pos) {
	if (isfinite(X)) {
		return F(fabs)(X);
	} else {
		occam_stop(pos,2,"Called (D)ABS on non-finite value: %f",X);
	}
}
static inline REAL ADD_PREFIX(COPYSIGN) (REAL, REAL, const char*) occam_unused;
static inline REAL ADD_PREFIX(COPYSIGN) (REAL X, REAL Y, const char* pos) {
	return F(copysign)(X,Y);
}
static inline REAL ADD_PREFIX(DIVBY2) (REAL, const char*) occam_unused;
static inline REAL ADD_PREFIX(DIVBY2) (REAL X, const char* pos) {
	if (isfinite(X)) {
		return F(scalbln)(X,-1);
	} else {
		occam_stop(pos,2,"Called (D)DIVBY2 on non-finite value: %f", X);
	}
}
static inline INT ADD_PREFIX(FLOATING_UNPACK) (REAL, REAL*, const char*) occam_unused;
static inline INT ADD_PREFIX(FLOATING_UNPACK) (REAL X, REAL* result1, const char* pos) {
	if (isnan(X) || X == 0) {
		//Finding the max exponent is a hack,
		//but frexp doesn't set the exponent when you pass
		//it a NAN so I can't see an easier way:
		*result1 = NAN;
		return (sizeof(X)*CHAR_BIT == 32 ? 0xFF : 0x7FF);
	} else {
		int E;
		//frexp returns in the range 0.5 to 1, but occam wants
		//the range 1 to 2, so we must double it, and subtrace
		//one from our return value:
		*result1 = F(scalbn)(F(frexp)(X,&E),1);
		return E - 1;
	}
}
static inline REAL ADD_PREFIX(FPINT) (REAL, const char*) occam_unused;
static inline REAL ADD_PREFIX(FPINT) (REAL X, const char* pos) {
	if (F(fabs)(X) >= F(exp2)(CHAR_BIT*sizeof(RINT))) {
		return X;
	} else {
		return F(nearbyint)(X);
	}
}
static inline BOOL ADD_PREFIX(ISNAN) (REAL, const char*) occam_unused;
static inline BOOL ADD_PREFIX(ISNAN) (REAL X, const char* pos) {
	return isnan(X);
}
static inline REAL ADD_PREFIX(LOGB) (REAL, const char*) occam_unused;
static inline REAL ADD_PREFIX(LOGB) (REAL X, const char* pos) {
	if (isnan(X)) {
		return X;
	} else if (!(isfinite(X))) {
		return INFINITY;
	} else if (X == 0) {
		return -INFINITY;
	} else {
		int E = 0;
		F(frexp)(X,&E);
		//Adjust because frexp puts it in the range 0.5--1 rather than 1--2:
		return E-1;
	}
	
}
static inline REAL ADD_PREFIX(MINUSX) (REAL, const char*) occam_unused;
static inline REAL ADD_PREFIX(MINUSX) (REAL X, const char* pos) {
	RINT iX = *(RINT*)&X;
	iX ^= __MIN(RINT); // Flip highest bit
	return *(REAL*)&iX;

}
static inline REAL ADD_PREFIX(MULBY2) (REAL, const char*) occam_unused;
static inline REAL ADD_PREFIX(MULBY2) (REAL X, const char* pos) {
	if (isfinite(X)) {
		return F(scalbln)(X,1);
	} else {
		occam_stop(pos,2,"Called (D)MULBY2 on non-finite value: %f", X);
	}
}
static inline REAL ADD_PREFIX(NEXTAFTER) (REAL, REAL, const char*) occam_unused;
static inline REAL ADD_PREFIX(NEXTAFTER) (REAL X, REAL Y, const char* pos) {
	return F(nextafter)(X,Y);
}
static inline BOOL ADD_PREFIX(NOTFINITE) (REAL, const char*) occam_unused;
static inline BOOL ADD_PREFIX(NOTFINITE) (REAL X, const char* pos) {
	return !(isfinite(X));
}
static inline BOOL ADD_PREFIX(ORDERED) (REAL, REAL, const char*) occam_unused;
static inline BOOL ADD_PREFIX(ORDERED) (REAL X, REAL Y, const char* pos) {
	return !(isunordered(X,Y));
}
static inline REAL ADD_PREFIX(SCALEB) (REAL, INT, const char*) occam_unused;
static inline REAL ADD_PREFIX(SCALEB) (REAL X, INT n, const char* pos) {
	if (isfinite(X)) {
		return F(scalbln)(X,n);
	} else {
		occam_stop(pos,2,"Called (D)SCALEB on non-finite value: %f", X);
	}
}
static inline REAL ADD_PREFIX(SQRT) (REAL, const char*) occam_unused;
static inline REAL ADD_PREFIX(SQRT) (REAL X, const char* pos) {
	if (isfinite(X) && X >= 0) {
		return F(sqrt)(X);
	} else {
		occam_stop(pos,2,"Called (D)SQRT on invalid input: %f", X);
	}
}

